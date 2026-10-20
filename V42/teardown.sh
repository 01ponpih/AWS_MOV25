#!/bin/bash
set -e

PROJECT_NAME="novatrix-web-vg"
KEY_NAME="novatrix-key"
SG_NAME="novatrix-sg-vg"

echo "Hittar instansen..."
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$PROJECT_NAME" "Name=instance-state-name,Values=running,pending,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [ "$INSTANCE_ID" != "None" ] && [ -n "$INSTANCE_ID" ]; then
    echo "Avslutar instans $INSTANCE_ID..."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
else
    echo "Ingen instans hittades."
fi

echo "Raderar säkerhetsgrupp..."
aws ec2 delete-security-group --group-name "$SG_NAME" || echo "Säkerhetsgruppen fanns inte."

echo "Raderar key pair..."
aws ec2 delete-key-pair --key-name "$KEY_NAME" || echo "Key pair fanns inte."

echo "Raderar lokal .pem-fil..."
rm -f "${KEY_NAME}.pem"

echo "Allt städat!"