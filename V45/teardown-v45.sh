#!/bin/bash
set -e
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"
load_ids

read -r -p "Detta raderar RDS, EFS och $BACKUP_BUCKET permanent. Skriv 'radera': " ANS
[ "$ANS" = "radera" ] || { echo "Avbryter."; exit 1; }

echo "== RDS"
if aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" >/dev/null 2>&1; then
  aws rds delete-db-instance --db-instance-identifier "$DB_INSTANCE" \
    --skip-final-snapshot --delete-automated-backups >/dev/null
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE"
fi
aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" 2>/dev/null || true

echo "== EFS"
EFS_ID=$(aws efs describe-file-systems --creation-token "$EFS_NAME" \
  --query 'FileSystems[0].FileSystemId' --output text 2>/dev/null || true)
if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
  for MT in $(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
    --query 'MountTargets[].MountTargetId' --output text); do
    aws efs delete-mount-target --mount-target-id "$MT"
  done
  until [ -z "$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
    --query 'MountTargets[].MountTargetId' --output text)" ]; do sleep 5; done
  aws efs delete-file-system --file-system-id "$EFS_ID"
fi
EFS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$EFS_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [ -n "$EFS_SG_ID" ] && [ "$EFS_SG_ID" != "None" ]; then
  for i in 1 2 3 4 5 6; do
    aws ec2 delete-security-group --group-id "$EFS_SG_ID" 2>/dev/null && break || sleep 10
  done
fi

echo "== S3"
if aws s3api head-bucket --bucket "$BACKUP_BUCKET" 2>/dev/null; then
  aws s3 rm "s3://$BACKUP_BUCKET" --recursive --only-show-errors
  aws s3api delete-bucket --bucket "$BACKUP_BUCKET"
fi

echo "== IAM + SSM"
aws iam delete-role-policy --role-name "$WEB_ROLE_NAME" --policy-name novatrix-v45-s3-backup 2>/dev/null || true
aws iam delete-role-policy --role-name "$WEB_ROLE_NAME" --policy-name novatrix-v45-ssm-read 2>/dev/null || true
for p in db-endpoint db-name db-user db-password wp-admin-password efs-id backup-bucket; do
  aws ssm delete-parameter --name "$SSM_PREFIX/$p" 2>/dev/null || true
done

echo "== NACL + db-sg"
PRIV_NACL_ID=$(lookup_nacl "$VPC_ID" "$PRIV_NACL_NAME")
aws ec2 delete-network-acl-entry --network-acl-id "$PRIV_NACL_ID" --rule-number 110 --ingress 2>/dev/null || true

NACL_ID=$(lookup_nacl "$VPC_ID" "$PUB_NACL_NAME")
aws ec2 delete-network-acl-entry --network-acl-id "$NACL_ID" --rule-number 140 --egress  2>/dev/null || true
aws ec2 delete-network-acl-entry --network-acl-id "$NACL_ID" --rule-number 150 --egress  2>/dev/null || true
aws ec2 delete-network-acl-entry --network-acl-id "$NACL_ID" --rule-number 160 --ingress 2>/dev/null || true
aws ec2 revoke-security-group-ingress --group-id "$DB_SG_ID" --protocol tcp --port 3306 \
  --source-group "$WEB_SG_ID" >/dev/null 2>&1 || true

echo "Klart."