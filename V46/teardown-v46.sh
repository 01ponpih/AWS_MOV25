#!/bin/bash
set -euo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
export MSYS_NO_PATHCONV=1

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DATA_BUCKET="novatrix-data-$ACCOUNT_ID"
BACKUP_BUCKET="novatrix-backup-$ACCOUNT_ID"

echo "== Tar bort CloudFormation-stackar (om de finns)"
for stack in novatrix-webb novatrix-data novatrix-natverk; do
  if aws cloudformation describe-stacks --stack-name "$stack" >/dev/null 2>&1; then
    echo "   Tar bort $stack..."
    aws cloudformation delete-stack --stack-name "$stack"
    aws cloudformation wait stack-delete-complete --stack-name "$stack"
    echo "   Klart: $stack"
  else
    echo "   = $stack finns inte"
  fi
done

echo "== Tar bort S3-buckets"
for bucket in "$DATA_BUCKET" "$BACKUP_BUCKET"; do
  if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    echo "   Tömmer och tar bort $bucket..."
    aws s3 rm "s3://$bucket" --recursive --only-show-errors
    aws s3api delete-bucket --bucket "$bucket"
    echo "   Klart: $bucket"
  else
    echo "   = $bucket finns inte"
  fi
done

echo ""
echo "============================================================"
echo " Teardown klart! Alla V46-resurser är borttagna."
echo "============================================================"