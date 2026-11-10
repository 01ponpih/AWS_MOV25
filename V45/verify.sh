#!/bin/bash
set -e
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"
load_ids

echo "========== RDS =========="
aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Class:DBInstanceClass,MultiAZ:MultiAZ,Public:PubliclyAccessible,Encrypted:StorageEncrypted,BackupDays:BackupRetentionPeriod,Endpoint:Endpoint.Address}' \
  --output table

echo ""
echo "========== EFS =========="
EFS_ID=$(aws efs describe-file-systems --creation-token "$EFS_NAME" \
  --query 'FileSystems[0].FileSystemId' --output text)
aws efs describe-file-systems --file-system-id "$EFS_ID" \
  --query 'FileSystems[0].{Id:FileSystemId,Encrypted:Encrypted,State:LifeCycleState}' --output table
aws efs describe-mount-targets --file-system-id "$EFS_ID" \
  --query 'MountTargets[].[AvailabilityZoneName,SubnetId,LifeCycleState]' --output table

echo ""
echo "========== S3 =========="
aws s3api get-bucket-lifecycle-configuration --bucket "$BACKUP_BUCKET" \
  --query 'Rules[0].{ID:ID,Status:Status,Prefix:Filter.Prefix,ExpiresAfterDays:Expiration.Days}' --output table
aws s3api get-public-access-block --bucket "$BACKUP_BUCKET" \
  --query 'PublicAccessBlockConfiguration' --output table
echo "Backuper:"
aws s3 ls "s3://$BACKUP_BUCKET/backup/" || echo "  (inga än)"

echo ""
echo "========== Säkerhet =========="
echo "--- db-sg:"
aws ec2 describe-security-groups --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions[].[FromPort,ToPort,UserIdGroupPairs[0].GroupId]' --output table
echo "--- efs-sg:"
aws ec2 describe-security-groups --filters "Name=group-name,Values=$EFS_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].IpPermissions[].[FromPort,ToPort,UserIdGroupPairs[0].GroupId]' --output table
echo "--- Inline-policyer:"
aws iam list-role-policies --role-name "$WEB_ROLE_NAME" --output table
echo "--- Managed policies:"
aws iam list-attached-role-policies --role-name "$WEB_ROLE_NAME" --output table
echo "--- NACL:"
PUB_NACL_ID=$(lookup_nacl "$VPC_ID" "$PUB_NACL_NAME")
aws ec2 describe-network-acls --network-acl-ids "$PUB_NACL_ID" \
  --query 'NetworkAcls[0].Entries[].[Egress,RuleNumber,RuleAction,PortRange.From,PortRange.To,CidrBlock]' --output table
echo "--- Privat NACL:"
PRIV_NACL_ID=$(lookup_nacl "$VPC_ID" "$PRIV_NACL_NAME")
aws ec2 describe-network-acls --network-acl-ids "$PRIV_NACL_ID" \
  --query 'NetworkAcls[0].Entries[].[Egress,RuleNumber,RuleAction,PortRange.From,PortRange.To,CidrBlock]' --output table
PUB=$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].PubliclyAccessible' --output text)
[ "$PUB" = "False" ] && echo "OK: RDS är privat." || echo "FEL: RDS är publik!"