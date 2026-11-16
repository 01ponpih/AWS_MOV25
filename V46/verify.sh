#!/bin/bash
set -e
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

echo "=========================================="
echo " V46 Verification"
echo "=========================================="

echo ""
echo "== 1. CloudFormation Stackar"
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?starts_with(StackName, 'novatrix')].[StackName,StackStatus]" \
  --output table

echo ""
echo "== 2. Exports (bevis på att stackarna kopplats ihop)"
aws cloudformation list-exports \
  --query "Exports[?starts_with(Name, 'novatrix')].[Name,Value]" \
  --output table

echo ""
echo "== 3. RDS-instans (dynamisk sökning eftersom CF genererar namnet)"
aws rds describe-db-instances \
  --query "DBInstances[?starts_with(DBInstanceIdentifier, 'novatrix-data')].{Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Public:PubliclyAccessible,Encrypted:StorageEncrypted,BackupDays:BackupRetentionPeriod,MultiAZ:MultiAZ,Identifier:DBInstanceIdentifier,Endpoint:Endpoint.Address}" \
  --output table

echo ""
echo "== 4. EFS (mount targets i båda subnäten)"
EFS_ID=$(aws cloudformation describe-stacks --stack-name novatrix-data \
  --query "Stacks[0].Outputs[?OutputKey=='EfsId'].OutputValue" --output text)
aws efs describe-mount-targets --file-system-id "$EFS_ID" \
  --query 'MountTargets[].[AvailabilityZoneName,LifeCycleState]' --output table

echo ""
echo "== 5. S3 Backup-bucket (lifecycle 14 dagar)"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3api get-bucket-lifecycle-configuration --bucket "novatrix-backup-$ACCOUNT_ID" \
  --query 'Rules[0].{ID:ID,Status:Status,Prefix:Filter.Prefix,ExpiresAfterDays:Expiration.Days}' \
  --output table

echo ""
echo "== 6. WordPress – HTTP-svar"
WEB_URL=$(aws cloudformation describe-stacks --stack-name novatrix-webb \
  --query "Stacks[0].Outputs[?OutputKey=='WebsiteUrl'].OutputValue" --output text)
echo "   Webbplats: $WEB_URL"

# Fångar HTTP-koden, ignorerar Windows/Git Bash-strul
HTTP_CODE=$(curl -s -L -o /dev/null --max-time 15 -w "%{http_code}" "$WEB_URL" 2>/dev/null || true)

# Kollar om svaret börjar med 200 eller 302, oavsett om det råkat hänga på extra nollor
if [[ "$HTTP_CODE" == 200* ]] || [[ "$HTTP_CODE" == 302* ]]; then
  echo "   OK: WordPress svarar med HTTP ${HTTP_CODE:0:3}"
else
  echo "   FEL: WordPress svarar inte (HTTP: $HTTP_CODE)."
  echo "   UserData kan fortfarande arbeta. Vänta 2 minuter och kör verify.sh igen."
fi

echo ""
echo "== 7. WordPress Admin-lösenord finns i Secrets Manager"
WP_SECRET=$(aws cloudformation describe-stacks --stack-name novatrix-webb \
  --query "Stacks[0].Outputs[?OutputKey=='WpAdminSecretArn'].OutputValue" --output text)
if aws secretsmanager describe-secret --secret-id "$WP_SECRET" >/dev/null 2>&1; then
  echo "   OK: Secret finns"
  echo "   Läs lösenordet med:"
  echo "   aws secretsmanager get-secret-value --secret-id $WP_SECRET --query SecretString --output text"
else
  echo "   FEL: Secrets Manager-härvan saknas"
fi

echo ""
echo "== 8. S3 Backup – finns en backup från första körningen?"
aws s3 ls "s3://novatrix-backup-$ACCOUNT_ID/backup/" 2>/dev/null || echo "   (inga backuper än – körs första gången vid cron 02:00 eller manuellt)"

echo ""
echo "=========================================="
echo " Klart! Granska ovanstående utskrifter."
echo "=========================================="