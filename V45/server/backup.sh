#!/bin/bash
set -euo pipefail

TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
export AWS_DEFAULT_REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

get_param() { aws ssm get-parameter --name "/novatrix/$1" --with-decryption \
  --query Parameter.Value --output text; }

DB_ENDPOINT=$(get_param db-endpoint)
DB_NAME=$(get_param db-name)
DB_USER=$(get_param db-user)
DB_PASSWORD=$(get_param db-password)
BUCKET=$(get_param backup-bucket)

TS=$(date +%Y%m%d-%H%M%S)
FILE="/tmp/${DB_NAME}-${TS}.sql.gz"
trap 'rm -f "$FILE"' EXIT

echo "[$(date -Is)] Dumpar $DB_NAME från $DB_ENDPOINT"
MYSQL_PWD="$DB_PASSWORD" mysqldump --ssl \
  --host="$DB_ENDPOINT" --user="$DB_USER" \
  --single-transaction --quick --no-tablespaces \
  "$DB_NAME" | gzip -9 > "$FILE"

SIZE=$(du -h "$FILE" | cut -f1)
aws s3 cp "$FILE" "s3://${BUCKET}/backup/${DB_NAME}-${TS}.sql.gz" --only-show-errors
echo "[$(date -Is)] Klart: s3://${BUCKET}/backup/${DB_NAME}-${TS}.sql.gz (${SIZE})"