#!/bin/bash
if [ -z "$1" ]; then
  echo "FEL: Ange ditt konto-ID som argument. Exempel: bash verify.sh 373117960549"
  exit 1
fi

ACCOUNT_ID="$1"
DATA="novatrix-data-${ACCOUNT_ID}"
LOGS="novatrix-logs-${ACCOUNT_ID}"
export AWS_DEFAULT_REGION=eu-north-1

mkdir -p ~/.aws
cat > ~/.aws/config << EOF
[profile logwriter]
role_arn = arn:aws:iam::${ACCOUNT_ID}:role/novatrix-logwriter-role
credential_source = Ec2InstanceMetadata
region = eu-north-1
EOF

echo "x" > x.txt

echo "1. Läsa data (ska fungera):"
aws s3 ls "s3://$DATA"

echo "2. Radera data (ska nekas):"
aws s3 rm "s3://$DATA/test.txt"

echo "3. Skriva till data (ska nekas):"
aws s3 cp x.txt "s3://$DATA/x.txt"

echo "4. Skriva loggar utan kedja (ska nekas):"
aws s3 cp x.txt "s3://$LOGS/x.txt"

echo "5. Skriva loggar via kedjan (ska fungera):"
aws s3 cp x.txt "s3://$LOGS/x.txt" --profile logwriter

echo "6. Kedjerollen mot data (ska nekas):"
aws s3 cp x.txt "s3://$DATA/x.txt" --profile logwriter