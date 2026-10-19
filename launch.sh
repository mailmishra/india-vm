#!/bin/bash
set -e
source "$(dirname "$0")/config.sh"

# ── Helper ─────────────────────────────────────────────────────────────────
log() { echo "▶ $1"; }

# ── 1. IAM user (for running these scripts locally — least privilege) ──────
if ! aws iam get-user --user-name "$IAM_USER" &>/dev/null; then
  log "Creating IAM user: $IAM_USER"
  aws iam create-user --user-name "$IAM_USER"

  # Inline policy: only what's needed — EC2 spot + S3 bucket + IAM PassRole
  aws iam put-user-policy \
    --user-name "$IAM_USER" \
    --policy-name "india-vm-policy" \
    --policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": [
            "ec2:RunInstances", "ec2:TerminateInstances",
            "ec2:DescribeInstances", "ec2:DescribeInstanceStatus",
            "ec2:CreateSecurityGroup", "ec2:AuthorizeSecurityGroupIngress",
            "ec2:DescribeSecurityGroups", "ec2:CreateKeyPair",
            "ec2:DescribeKeyPairs", "ec2:CreateTags"
          ],
          "Resource": "*"
        },
        {
          "Effect": "Allow",
          "Action": ["s3:*"],
          "Resource": [
            "arn:aws:s3:::'"$S3_BUCKET"'",
            "arn:aws:s3:::'"$S3_BUCKET"'/*"
          ]
        },
        {
          "Effect": "Allow",
          "Action": "iam:PassRole",
          "Resource": "arn:aws:iam::*:role/'"$IAM_ROLE"'"
        }
      ]
    }'

  log "Creating access keys for $IAM_USER"
  CREDS=$(aws iam create-access-key --user-name "$IAM_USER")
  ACCESS_KEY=$(echo "$CREDS" | python3 -c "import sys,json; d=json.load(sys.stdin)['AccessKey']; print(d['AccessKeyId'])")
  SECRET_KEY=$(echo "$CREDS" | python3 -c "import sys,json; d=json.load(sys.stdin)['AccessKey']; print(d['SecretAccessKey'])")

  # Save credentials to AWS profile
  aws configure set aws_access_key_id "$ACCESS_KEY" --profile india-vm
  aws configure set aws_secret_access_key "$SECRET_KEY" --profile india-vm
  aws configure set region "$REGION" --profile india-vm
  log "Credentials saved to AWS profile 'india-vm'"
  log "Future runs: use 'export AWS_PROFILE=india-vm' or this script handles it"
else
  log "IAM user $IAM_USER already exists — skipping"
fi

# ── 2. EC2 Key Pair ────────────────────────────────────────────────────────
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &>/dev/null; then
  log "Creating key pair: $KEY_NAME"
  aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --region "$REGION" \
    --query 'KeyMaterial' \
    --output text > "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  log "Key saved to $KEY_FILE"
else
  log "Key pair $KEY_NAME already exists — skipping"
fi

# ── 3. Security Group ──────────────────────────────────────────────────────
SG_ID=$(aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "None")

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  log "Creating security group: $SECURITY_GROUP_NAME"
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SECURITY_GROUP_NAME" \
    --description "RDP access for india-vm" \
    --region "$REGION" \
    --query 'GroupId' \
    --output text)

  MY_IP=$(curl -s https://checkip.amazonaws.com)
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 3389 \
    --cidr "${MY_IP}/32" \
    --region "$REGION"
  log "Security group $SG_ID created — RDP open for your IP: $MY_IP"
else
  log "Security group $SECURITY_GROUP_NAME already exists ($SG_ID) — skipping"
fi

# ── 4. IAM role for instance (S3 access without credentials on VM) ─────────
if ! aws iam get-role --role-name "$IAM_ROLE" &>/dev/null; then
  log "Creating IAM role: $IAM_ROLE"
  aws iam create-role \
    --role-name "$IAM_ROLE" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "ec2.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }'
  aws iam attach-role-policy \
    --role-name "$IAM_ROLE" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  aws iam create-instance-profile --instance-profile-name "$IAM_ROLE" &>/dev/null || true
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$IAM_ROLE" \
    --role-name "$IAM_ROLE"
  sleep 15  # new instance profiles take a few seconds to propagate to EC2
  log "IAM role $IAM_ROLE created"
else
  log "IAM role $IAM_ROLE already exists — skipping"
fi

# ── 5. S3 Bucket ───────────────────────────────────────────────────────────
if ! aws s3 ls "s3://$S3_BUCKET" &>/dev/null; then
  log "Creating S3 bucket: $S3_BUCKET"
  aws s3 mb "s3://$S3_BUCKET" --region "$REGION"
else
  log "S3 bucket $S3_BUCKET already exists — skipping"
fi

# Steps 1-5 need admin rights (the user's policy names the old bucket); switch to the least-privilege user from here on
if aws configure list --profile india-vm &>/dev/null; then
  export AWS_PROFILE=india-vm
fi
# New access keys take a few seconds to propagate (else AuthFailure)
until aws sts get-caller-identity &>/dev/null; do sleep 3; done

# ── 6. Check for already-running instance ─────────────────────────────────
EXISTING=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:Name,Values=india-windows" \
    "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
  PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$EXISTING" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
  log "Instance already running: $EXISTING"
  echo ""
  echo "✓ RDP to: $PUBLIC_IP"
  echo "  Username: Administrator"
  exit 0
fi

# ── 7. Launch spot instance ────────────────────────────────────────────────
USER_DATA=$(cat <<USERDATA
<powershell>
Set-ExecutionPolicy Bypass -Scope Process -Force
iex ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
C:\ProgramData\chocolatey\bin\choco.exe install -y winfsp $SOFTWARE
# Chrome's choco package pins a checksum for a moving "latest" URL, so it goes stale
C:\ProgramData\chocolatey\bin\choco.exe install -y googlechrome --ignore-checksums

Invoke-WebRequest https://downloads.rclone.org/rclone-current-windows-amd64.zip -OutFile C:\rclone.zip
Expand-Archive C:\rclone.zip -DestinationPath C:\rclone
\$rclone = (Get-ChildItem C:\rclone -Recurse -Filter rclone.exe).FullName

\$config = @"
[s3]
type = s3
provider = AWS
env_auth = true
region = $REGION
"@
\$config | Out-File C:\rclone\rclone.conf -Encoding ASCII

# Mount at every logon, in the user's own (non-elevated) session so Z: shows up in Explorer
\$action = New-ScheduledTaskAction -Execute \$rclone -Argument "mount s3:$S3_BUCKET Z: --vfs-cache-mode full --config C:\rclone\rclone.conf --no-console"
\$trigger = New-ScheduledTaskTrigger -AtLogOn
\$principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited
Register-ScheduledTask -TaskName MountS3 -Action \$action -Trigger \$trigger -Principal \$principal
</powershell>
USERDATA
)

log "Launching spot instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile Name="$IAM_ROLE" \
  --user-data "$USER_DATA" \
  --instance-market-options '{"MarketType":"spot"}' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=india-windows}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

log "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo ""
echo "✓ Ready! RDP to: $PUBLIC_IP"
echo "  Username : Administrator"
echo "  Password : AWS Console → EC2 → Instances → Connect → RDP client → Get password"
echo "             Use key file: $KEY_FILE"
echo "  S3 drive : Z: (available ~2 min after login)"
