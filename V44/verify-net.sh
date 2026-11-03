#!/bin/bash
export AWS_PAGER=""
export AWS_DEFAULT_REGION="eu-north-1"

KEY="$1"
if [ ! -f "$KEY" ]; then
  echo "Ange sökvägen till .pem-filen. Exempel: bash verify-net.sh ../V42/novatrix-key.pem"
  exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

get() { aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].$2" --output text; }
BASTION_IP=$(get novatrix-bastion PublicIpAddress)
WEB_IP=$(get novatrix-web PublicIpAddress)
WEB_PRIV=$(get novatrix-web PrivateIpAddress)
echo "Bastion: $BASTION_IP   Webb: $WEB_IP (privat $WEB_PRIV)"
echo "-----------------------------------------------------"

echo "1. HTTP mot webben (ska fungera):"
curl -s -o /dev/null -m 5 -w "HTTP %{http_code}\n" "http://$WEB_IP"

echo "2. Stängd port 8080 (ska time-outa, curl-exit 28):"
curl -s -o /dev/null -m 5 "http://$WEB_IP:8080"; echo "curl-exit: $?"

echo "3. SSH direkt mot webben (ska time-outa, ssh-exit 255):"
ssh -i "$KEY" -o ConnectTimeout=5 -o BatchMode=yes "ec2-user@$WEB_IP" true; echo "ssh-exit: $?"

echo "4. SSH mot bastionen (ska fungera):"
ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "ec2-user@$BASTION_IP" hostname

echo "5. Via bastionen till webben, och S3 med rollen (ska fungera):"
ssh -i "$KEY" -o StrictHostKeyChecking=accept-new \
  -o ProxyCommand="ssh -i $KEY -o StrictHostKeyChecking=accept-new -W %h:%p ec2-user@$BASTION_IP" \
  "ec2-user@$WEB_PRIV" "hostname; aws s3 ls s3://novatrix-data-$ACCOUNT_ID"