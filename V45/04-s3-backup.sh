#!/bin/bash
set -eE
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"

echo "== 1/4: Bucket $BACKUP_BUCKET"
if aws s3api head-bucket --bucket "$BACKUP_BUCKET" 2>/dev/null; then
  echo "   = finns redan"
else
  aws s3api create-bucket --bucket "$BACKUP_BUCKET" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  echo "   + skapad"
fi

echo "== 2/4: Härdning (block public, kryptering, TLS)"
aws s3api put-public-access-block --bucket "$BACKUP_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption --bucket "$BACKUP_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-bucket-policy --bucket "$BACKUP_BUCKET" --policy "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": ["arn:aws:s3:::${BACKUP_BUCKET}", "arn:aws:s3:::${BACKUP_BUCKET}/*"],
    "Condition": {"Bool": {"aws:SecureTransport": "false"}}
  }]
}
EOF
)"

echo "== 3/4: Livscykelregel (14 dagar)"
aws s3api put-bucket-lifecycle-configuration --bucket "$BACKUP_BUCKET" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "expire-backups-14-days",
      "Status": "Enabled",
      "Filter": {"Prefix": "backup/"},
      "Expiration": {"Days": 14},
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
    }]
  }'
ssm_put backup-bucket "$BACKUP_BUCKET"

echo "== 4/4: IAM-policyer på $WEB_ROLE_NAME"
aws iam get-role --role-name "$WEB_ROLE_NAME" >/dev/null

aws iam put-role-policy --role-name "$WEB_ROLE_NAME" \
  --policy-name novatrix-v45-s3-backup \
  --policy-document "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "WriteBackups",
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:AbortMultipartUpload"],
    "Resource": "arn:aws:s3:::${BACKUP_BUCKET}/backup/*"
  }]
}
EOF
)"

aws iam put-role-policy --role-name "$WEB_ROLE_NAME" \
  --policy-name novatrix-v45-ssm-read \
  --policy-document "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "ReadOwnConfig",
    "Effect": "Allow",
    "Action": "ssm:GetParameter",
    "Resource": "arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter${SSM_PREFIX}/*"
  }]
}
EOF
)"
echo "   + IAM-policyer uppdaterade"
echo "   Väntar 15 sekunder på att IAM-policyerna sprids..."
sleep 15