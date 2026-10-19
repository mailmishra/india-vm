#!/bin/bash
set -e
source "$(dirname "$0")/config.sh"

INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:Name,Values=india-windows" \
    "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

if [ "$INSTANCE_ID" = "None" ] || [ -z "$INSTANCE_ID" ]; then
  echo "No running india-windows instance found."
  exit 0
fi

echo "▶ Terminating $INSTANCE_ID..."
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
echo "✓ Terminated. No further compute charges."
