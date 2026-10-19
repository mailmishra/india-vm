# ── Edit these values ──────────────────────────────────────────────────────
INSTANCE_TYPE="t3.medium"        # Windows needs more than t3.small's 2GB RAM
REGION="ap-south-1"
# Latest Windows Server 2022 AMI, resolved from AWS's public SSM parameter
AMI_ID=$(aws ssm get-parameter --region "$REGION" \
  --name /aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base \
  --query Parameter.Value --output text)
SOFTWARE="7zip vscode"          # Chocolatey package names, space-separated (https://community.chocolatey.org/packages)
S3_BUCKET="amit-vm-personal-data"   # S3 bucket name (will be created if missing)

# ── These are created automatically by launch.sh if missing ───────────────
KEY_NAME="india-vm-key"
SECURITY_GROUP_NAME="india-vm-rdp"
IAM_USER="india-vm-user"
IAM_ROLE="india-vm-s3-role"
KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"

#--- Aws Profile --
AWS_PROFILE="aws-india"
