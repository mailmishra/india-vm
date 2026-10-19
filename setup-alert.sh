#!/bin/bash
set -e
source "$(dirname "$0")/config.sh"

ALERT_EMAIL="mailmishra@gmail.com"
SNS_TOPIC_NAME="india-vm-alert"
LAMBDA_NAME="india-vm-checker"
TERMINATE_LAMBDA_NAME="india-vm-terminator"
RULE_NAME="india-vm-daily-check"
LAMBDA_ROLE="india-vm-lambda-role"
TOKEN_PARAM="/india-vm/terminate-token"

log() { echo "▶ $1"; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ── 1. Secret token in SSM (one-time, never rotates) ──────────────────────
if ! aws ssm get-parameter --name "$TOKEN_PARAM" --region "$REGION" &>/dev/null; then
  log "Generating terminate token in SSM"
  TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
  aws ssm put-parameter \
    --name "$TOKEN_PARAM" \
    --value "$TOKEN" \
    --type SecureString \
    --region "$REGION" > /dev/null
else
  log "Terminate token already exists in SSM — skipping"
  TOKEN=$(aws ssm get-parameter --name "$TOKEN_PARAM" --with-decryption \
    --region "$REGION" --query Parameter.Value --output text)
fi

# ── 2. SNS topic + email subscription ─────────────────────────────────────
TOPIC_ARN=$(aws sns list-topics --region "$REGION" \
  --query "Topics[?ends_with(TopicArn, ':$SNS_TOPIC_NAME')].TopicArn" \
  --output text)

if [ -z "$TOPIC_ARN" ]; then
  log "Creating SNS topic: $SNS_TOPIC_NAME"
  TOPIC_ARN=$(aws sns create-topic --name "$SNS_TOPIC_NAME" --region "$REGION" --query TopicArn --output text)
  aws sns subscribe \
    --topic-arn "$TOPIC_ARN" \
    --protocol email \
    --notification-endpoint "$ALERT_EMAIL" \
    --region "$REGION" > /dev/null
  echo ""
  echo "  ⚠ Check $ALERT_EMAIL and confirm the AWS subscription email before alerts will work."
  echo ""
else
  log "SNS topic already exists — skipping"
fi

# ── 3. IAM role for Lambda ─────────────────────────────────────────────────
if ! aws iam get-role --role-name "$LAMBDA_ROLE" &>/dev/null; then
  log "Creating Lambda IAM role: $LAMBDA_ROLE"
  aws iam create-role \
    --role-name "$LAMBDA_ROLE" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "lambda.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }'
  aws iam attach-role-policy \
    --role-name "$LAMBDA_ROLE" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  aws iam put-role-policy \
    --role-name "$LAMBDA_ROLE" \
    --policy-name "india-vm-lambda-policy" \
    --policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": [
            "ec2:DescribeInstances",
            "ec2:DescribeSpotPriceHistory",
            "ec2:TerminateInstances"
          ],
          "Resource": "*"
        },
        {
          "Effect": "Allow",
          "Action": "sns:Publish",
          "Resource": "'"$TOPIC_ARN"'"
        },
        {
          "Effect": "Allow",
          "Action": "ssm:GetParameter",
          "Resource": "arn:aws:ssm:'"$REGION"':'"$ACCOUNT_ID"':parameter'"$TOKEN_PARAM"'"
        }
      ]
    }'
  sleep 10  # IAM propagation delay
else
  log "Lambda role already exists — skipping"
fi

LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE}"

# ── 4. Terminator Lambda (called by API Gateway) ───────────────────────────
cat > /tmp/india_vm_terminator.py <<PYEOF
import boto3, os

REGION = '${REGION}'
TOKEN_PARAM = '${TOKEN_PARAM}'

def handler(event, context):
    token = event.get('queryStringParameters', {}).get('token', '')

    ssm = boto3.client('ssm', region_name=REGION)
    expected = ssm.get_parameter(Name=TOKEN_PARAM, WithDecryption=True)['Parameter']['Value']

    if token != expected:
        return {'statusCode': 403, 'body': 'Invalid token.'}

    ec2 = boto3.client('ec2', region_name=REGION)
    reservations = ec2.describe_instances(Filters=[
        {'Name': 'tag:Name', 'Values': ['india-windows']},
        {'Name': 'instance-state-name', 'Values': ['running', 'pending']}
    ])['Reservations']

    if not reservations:
        return {'statusCode': 200, 'body': 'No running instance found — already terminated?'}

    instance_id = reservations[0]['Instances'][0]['InstanceId']
    ec2.terminate_instances(InstanceIds=[instance_id])
    return {'statusCode': 200, 'body': f'Instance {instance_id} terminated successfully.'}
PYEOF

(cd /tmp && zip -q india-vm-terminator.zip india_vm_terminator.py)

if ! aws lambda get-function --function-name "$TERMINATE_LAMBDA_NAME" --region "$REGION" &>/dev/null; then
  log "Creating terminator Lambda"
  aws lambda create-function \
    --function-name "$TERMINATE_LAMBDA_NAME" \
    --runtime python3.12 \
    --role "$LAMBDA_ROLE_ARN" \
    --handler india_vm_terminator.handler \
    --zip-file "fileb:///tmp/india-vm-terminator.zip" \
    --region "$REGION" \
    --timeout 30 > /dev/null
else
  log "Updating terminator Lambda code"
  aws lambda update-function-code \
    --function-name "$TERMINATE_LAMBDA_NAME" \
    --zip-file "fileb:///tmp/india-vm-terminator.zip" \
    --region "$REGION" > /dev/null
fi

TERMINATE_LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${TERMINATE_LAMBDA_NAME}"

# ── 5. API Gateway → terminator Lambda ────────────────────────────────────
API_ID=$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='india-vm-api'].ApiId" --output text)

if [ -z "$API_ID" ]; then
  log "Creating API Gateway"
  API_ID=$(aws apigatewayv2 create-api \
    --name "india-vm-api" \
    --protocol-type HTTP \
    --region "$REGION" \
    --query ApiId --output text)

  INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id "$API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri "$TERMINATE_LAMBDA_ARN" \
    --payload-format-version "2.0" \
    --region "$REGION" \
    --query IntegrationId --output text)

  aws apigatewayv2 create-route \
    --api-id "$API_ID" \
    --route-key "GET /terminate" \
    --target "integrations/$INTEGRATION_ID" \
    --region "$REGION" > /dev/null

  aws apigatewayv2 create-stage \
    --api-id "$API_ID" \
    --stage-name '$default' \
    --auto-deploy \
    --region "$REGION" > /dev/null

  aws lambda add-permission \
    --function-name "$TERMINATE_LAMBDA_NAME" \
    --statement-id "apigw-invoke" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*/terminate" \
    --region "$REGION" > /dev/null
else
  log "API Gateway already exists — skipping"
fi

TERMINATE_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/terminate?token=${TOKEN}"

# ── 6. Checker Lambda (alert email with terminate link) ───────────────────
LAMBDA_ZIP="/tmp/india-vm-checker.zip"

cat > /tmp/india_vm_checker.py <<PYEOF
import boto3
from datetime import datetime, timezone

REGION = '${REGION}'
TERMINATE_URL = '${TERMINATE_URL}'

def get_spot_price(ec2, instance_type):
    try:
        resp = ec2.describe_spot_price_history(
            InstanceTypes=[instance_type],
            ProductDescriptions=['Windows'],
            MaxResults=1
        )
        prices = resp.get('SpotPriceHistory', [])
        return float(prices[0]['SpotPrice']) if prices else None
    except Exception:
        return None

def handler(event, context):
    ec2 = boto3.client('ec2', region_name=REGION)
    sns = boto3.client('sns', region_name=REGION)

    reservations = ec2.describe_instances(Filters=[
        {'Name': 'tag:Name', 'Values': ['india-windows']},
        {'Name': 'instance-state-name', 'Values': ['running', 'pending']}
    ])['Reservations']

    if not reservations:
        return  # not running, no alert needed

    instance = reservations[0]['Instances'][0]
    instance_id = instance['InstanceId']
    public_ip = instance.get('PublicIpAddress', 'unknown')
    instance_type = instance['InstanceType']
    launch_time = instance['LaunchTime']

    now = datetime.now(timezone.utc)
    uptime = now - launch_time
    uptime_hours = uptime.total_seconds() / 3600
    days = uptime.days
    hours = int((uptime.total_seconds() % 86400) // 3600)
    minutes = int((uptime.total_seconds() % 3600) // 60)
    uptime_str = f"{days}d {hours}h {minutes}m" if days > 0 else f"{hours}h {minutes}m"

    spot_price = get_spot_price(ec2, instance_type)
    if spot_price:
        estimated_cost = spot_price * uptime_hours
        cost_str = f"\${estimated_cost:.4f} USD  ({uptime_hours:.1f} hrs × \${spot_price:.4f}/hr spot price)"
    else:
        cost_str = "unavailable (could not fetch spot price)"

    sns.publish(
        TopicArn='${TOPIC_ARN}',
        Subject='⚠ india-vm is still running!',
        Message=f"""Your India VM is still running — you may be getting charged.

Instance ID   : {instance_id}
Instance type : {instance_type}
Public IP     : {public_ip}
Uptime        : {uptime_str}  (started {launch_time.strftime('%Y-%m-%d %H:%M UTC')})
Estimated cost: {cost_str}

──────────────────────────────────────
TERMINATE WITH ONE CLICK:
{TERMINATE_URL}
──────────────────────────────────────

Or run locally: ./terminate.sh
"""
    )
PYEOF

(cd /tmp && zip -q india-vm-checker.zip india_vm_checker.py)

if ! aws lambda get-function --function-name "$LAMBDA_NAME" --region "$REGION" &>/dev/null; then
  log "Creating checker Lambda"
  aws lambda create-function \
    --function-name "$LAMBDA_NAME" \
    --runtime python3.12 \
    --role "$LAMBDA_ROLE_ARN" \
    --handler india_vm_checker.handler \
    --zip-file "fileb://$LAMBDA_ZIP" \
    --region "$REGION" \
    --timeout 30 > /dev/null
else
  log "Updating checker Lambda code"
  aws lambda update-function-code \
    --function-name "$LAMBDA_NAME" \
    --zip-file "fileb://$LAMBDA_ZIP" \
    --region "$REGION" > /dev/null
fi

LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${LAMBDA_NAME}"

# ── 7. EventBridge rule — every 24 hours ──────────────────────────────────
if ! aws events describe-rule --name "$RULE_NAME" --region "$REGION" &>/dev/null; then
  log "Creating EventBridge rule: every 24 hours"
  aws events put-rule \
    --name "$RULE_NAME" \
    --schedule-expression "rate(24 hours)" \
    --state ENABLED \
    --region "$REGION" > /dev/null

  aws lambda add-permission \
    --function-name "$LAMBDA_NAME" \
    --statement-id "eventbridge-invoke" \
    --action lambda:InvokeFunction \
    --principal events.amazonaws.com \
    --source-arn "arn:aws:events:${REGION}:${ACCOUNT_ID}:rule/${RULE_NAME}" \
    --region "$REGION" > /dev/null

  aws events put-targets \
    --rule "$RULE_NAME" \
    --targets "Id=1,Arn=$LAMBDA_ARN" \
    --region "$REGION" > /dev/null
else
  log "EventBridge rule already exists — skipping"
fi

echo ""
echo "✓ Alert set up. Email: $ALERT_EMAIL"
echo "✓ Terminate URL: $TERMINATE_URL"
echo "  (Confirm the SNS subscription email first or alerts won't send.)"
