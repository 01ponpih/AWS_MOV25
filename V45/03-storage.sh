#!/bin/bash
set -eE
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"
load_ids

echo "== 1/6: Security group $EFS_SG_NAME"
EFS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$EFS_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$EFS_SG_ID" = "None" ] || [ -z "$EFS_SG_ID" ]; then
  EFS_SG_ID=$(aws ec2 create-security-group \
    --group-name "$EFS_SG_NAME" --description "Novatrix EFS NFS" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$EFS_SG_NAME}]" \
    --query GroupId --output text)
  echo "   + skapad: $EFS_SG_ID"
else
  echo "   = finns redan"
fi
sg_allow "$EFS_SG_ID" 2049 "$WEB_SG_ID"

echo "== 2/6: Filsystem $EFS_NAME"
EFS_ID=$(aws efs describe-file-systems --creation-token "$EFS_NAME" \
  --query 'FileSystems[0].FileSystemId' --output text 2>/dev/null || true)
if [ "$EFS_ID" = "None" ] || [ -z "$EFS_ID" ]; then
  EFS_ID=$(aws efs create-file-system --creation-token "$EFS_NAME" \
    --performance-mode generalPurpose --throughput-mode bursting --encrypted \
    --tags Key=Name,Value="$EFS_NAME" --query FileSystemId --output text)
  echo "   + skapad: $EFS_ID"
else
  echo "   = finns redan"
fi
until [ "$(aws efs describe-file-systems --file-system-id "$EFS_ID" \
  --query 'FileSystems[0].LifeCycleState' --output text)" = "available" ]; do sleep 5; done

echo "== 3/6: Mount targets"
for SUBNET in "$PRIV_A_SUBNET_ID" "$PRIV_B_SUBNET_ID"; do
  EXIST=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
    --query "MountTargets[?SubnetId=='$SUBNET'].MountTargetId" --output text)
  if [ -z "$EXIST" ]; then
    aws efs create-mount-target --file-system-id "$EFS_ID" \
      --subnet-id "$SUBNET" --security-groups "$EFS_SG_ID" >/dev/null
    echo "   + mount target i $SUBNET"
  else
    echo "   = finns redan i $SUBNET"
  fi
done
until [ -z "$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
  --query 'MountTargets[?LifeCycleState!=`available`].MountTargetId' --output text)" ]; do sleep 5; done

echo "== 4/6: Livscykel (IA 30 dagar) + TLS-policy"
aws efs put-lifecycle-configuration --file-system-id "$EFS_ID" \
  --lifecycle-policies TransitionToIA=AFTER_30_DAYS >/dev/null

POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowMount",
      "Effect": "Allow",
      "Principal": {"AWS": "*"},
      "Action": ["elasticfilesystem:ClientMount","elasticfilesystem:ClientWrite","elasticfilesystem:ClientRootAccess"],
      "Resource": "arn:aws:elasticfilesystem:${REGION}:${ACCOUNT_ID}:file-system/${EFS_ID}"
    },
    {
      "Sid": "DenyUnencryptedTransport",
      "Effect": "Deny",
      "Principal": {"AWS": "*"},
      "Action": "*",
      "Resource": "arn:aws:elasticfilesystem:${REGION}:${ACCOUNT_ID}:file-system/${EFS_ID}",
      "Condition": {"Bool": {"aws:SecureTransport": "false"}}
    }
  ]
}
EOF
)
aws efs put-file-system-policy --file-system-id "$EFS_ID" --policy "$POLICY" >/dev/null
echo "   + policy satt"

echo "== 5/6: Sparar EFS-ID i SSM"
ssm_put efs-id "$EFS_ID"

echo "== 6/6: AZ-kontroll"
WEB_AZ=$(aws ec2 describe-subnets --subnet-ids "$PUB_SUBNET_ID" \
  --query 'Subnets[0].AvailabilityZone' --output text)
MT_AZS=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
  --query 'MountTargets[].AvailabilityZoneName' --output text)
if [[ "$MT_AZS" == *"$WEB_AZ"* ]]; then
  echo "   OK: mount target i $WEB_AZ finns"
else
  echo "   VARNING: webbservern ligger i $WEB_AZ, men mount targets finns bara i: $MT_AZS"
fi

echo ""
echo "EFS-ID: $EFS_ID"