#!/bin/bash
set -eE
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"
ensure_secrets
load_ids

echo "== 1/5: Öppnar 3306 i $DB_SG_NAME från $WEB_SG_NAME"
sg_allow "$DB_SG_ID" 3306 "$WEB_SG_ID"

echo "== 2/5: DB subnet group"
if aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
  echo "   = finns redan"
else
  aws rds create-db-subnet-group \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "Novatrix privata subnat for RDS" \
    --subnet-ids "$PRIV_A_SUBNET_ID" "$PRIV_B_SUBNET_ID" \
    --tags Key=Name,Value="$DB_SUBNET_GROUP" >/dev/null
  echo "   + skapad"
fi

echo "== 3/5: RDS-instans $DB_INSTANCE"
if aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" >/dev/null 2>&1; then
  echo "   = finns redan"
else
  ENGINE_ARGS=()
  [ -n "$DB_ENGINE_VERSION" ] && ENGINE_ARGS=(--engine-version "$DB_ENGINE_VERSION")

  aws rds create-db-instance \
    --db-instance-identifier "$DB_INSTANCE" \
    --engine "$DB_ENGINE" \
    "${ENGINE_ARGS[@]}" \
    --db-instance-class "$DB_CLASS" \
    --allocated-storage "$DB_STORAGE" \
    --storage-type gp2 \
    --storage-encrypted \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASSWORD" \
    --db-name "$DB_NAME" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --vpc-security-group-ids "$DB_SG_ID" \
    --no-publicly-accessible \
    --no-multi-az \
    --backup-retention-period "$DB_BACKUP_DAYS" \
    --copy-tags-to-snapshot \
    --tags Key=Name,Value="$DB_INSTANCE" >/dev/null
  echo "   + skapad"
fi

echo "== 4/5: Väntar på att RDS blir tillgänglig (5-10 min)..."
aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE"
DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "   Endpoint: $DB_ENDPOINT"

echo "== 5/5: Sparar konfiguration i SSM"
ssm_put db-endpoint "$DB_ENDPOINT"
ssm_put db-name "$DB_NAME"
ssm_put db-user "$DB_USER"
ssm_put db-password "$DB_PASSWORD" SecureString
ssm_put wp-admin-password "$WP_ADMIN_PASSWORD" SecureString

aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].[DBInstanceStatus,PubliclyAccessible,BackupRetentionPeriod,EngineVersion]' \
  --output table