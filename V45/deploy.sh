#!/bin/bash
set -e
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
DIR="$(cd "$(dirname "$0")" && pwd)"
KEY="${KEY:-../V44/novatrix-key.pem}"

"$DIR/01-network.sh"
"$DIR/02-database.sh"
"$DIR/03-storage.sh"
"$DIR/04-s3-backup.sh"

echo ""
echo "============================================================"
echo " Infrastrukturen är klar. Startar automatisk server-setup..."
echo "============================================================"

q() { aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].$2" --output text; }
BASTION_IP=$(q novatrix-bastion PublicIpAddress)
WEB_PRIV_IP=$(q novatrix-web PrivateIpAddress)
WEB_PUB_DNS=$(q novatrix-web PublicDnsName)

if [ -z "$WEB_PUB_DNS" ] || [ "$WEB_PUB_DNS" = "None" ]; then
  WEB_PUB_DNS=$(q novatrix-web PublicIpAddress)
fi

echo ""
echo "Väntar 20 sekunder på att IAM-policyerna ska spridas i AWS..."
sleep 20

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
PROXY_CMD="ssh -i $KEY -W %h:%p ec2-user@$BASTION_IP"

echo "1/2: Kopierar server-skripten via bastionen..."
scp -i "$KEY" $SSH_OPTS -o ProxyCommand="$PROXY_CMD" -r "$DIR/server" ec2-user@$WEB_PRIV_IP:~/

echo "2/2: Loggar in och installerar WordPress (kan ta 2-3 minuter)..."
# timeout 600 ser till att hela SSH-anslutningen dör om något går fel
timeout 600 ssh -i "$KEY" $SSH_OPTS -o ProxyCommand="$PROXY_CMD" ec2-user@$WEB_PRIV_IP \
  "export SITE_HOST='$WEB_PUB_DNS' && cd server && chmod +x *.sh && sudo -E ./setup-wordpress.sh"

echo ""
echo "============================================================"
echo " ALLT KLART!"
echo " Webbplats: http://$WEB_PUB_DNS/"
echo " Admin:     http://$WEB_PUB_DNS/wp-admin"
echo ""
echo " Kör 'bash verify.sh' för att samla bevis."
echo "============================================================"