#!/bin/bash
set -euo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

PREFIX="${PREFIX:-novatrix}"
KEY_NAME="${KEY_NAME:-novatrix-key}"
DB_CLASS="${DB_CLASS:-db.t3.micro}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DATA_BUCKET="${DATA_BUCKET:-novatrix-data-$ACCOUNT_ID}"
BACKUP_BUCKET="${BACKUP_BUCKET:-novatrix-backup-$ACCOUNT_ID}"

if [ -z "${MY_IP:-}" ]; then
  MY_IP="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')/32"
fi
[[ "$MY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || { echo "FEL: ogiltig MY_IP: $MY_IP"; exit 1; }

echo "== Förkontroller"
aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null \
  || { echo "FEL: key pair '$KEY_NAME' saknas i $AWS_DEFAULT_REGION"; exit 1; }

ensure_bucket() {
  local b=$1
  if aws s3api head-bucket --bucket "$b" 2>/dev/null; then
    echo "   = bucket $b finns"
    return 0
  fi
  echo "   + skapar bucket $b"
  aws s3api create-bucket --bucket "$b" \
    --create-bucket-configuration "LocationConstraint=$AWS_DEFAULT_REGION" >/dev/null
  aws s3api put-public-access-block --bucket "$b" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  if [ "$b" = "$BACKUP_BUCKET" ]; then
    aws s3api put-bucket-lifecycle-configuration --bucket "$b" --lifecycle-configuration \
      '{"Rules":[{"ID":"expire-backups-14-days","Status":"Enabled","Filter":{"Prefix":"backup/"},"Expiration":{"Days":14},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}'
  fi
}
ensure_bucket "$DATA_BUCKET"
ensure_bucket "$BACKUP_BUCKET"

echo "== Validerar templates"
for t in natverk data webb; do
  aws cloudformation validate-template --template-body "file://$t.yaml" >/dev/null
  echo "   OK $t.yaml"
done

TAGS="Project=$PREFIX ManagedBy=cloudformation"

echo "== 1/3 Stack $PREFIX-natverk"
aws cloudformation deploy --stack-name "$PREFIX-natverk" \
  --template-file natverk.yaml \
  --parameter-overrides "Prefix=$PREFIX" "MyIp=$MY_IP" \
  --no-fail-on-empty-changeset --tags $TAGS

echo "== 2/3 Stack $PREFIX-data (RDS tar ca 5-10 min)"
aws cloudformation deploy --stack-name "$PREFIX-data" \
  --template-file data.yaml \
  --parameter-overrides "Prefix=$PREFIX" "DbInstanceClass=$DB_CLASS" \
  --no-fail-on-empty-changeset --tags $TAGS

echo "== 3/3 Stack $PREFIX-webb"
# Vid felsökning kan man köra DISABLE_ROLLBACK=1 bash deploy-all.sh
ROLLBACK_FLAG=()
[ "${DISABLE_ROLLBACK:-0}" = "1" ] && ROLLBACK_FLAG=(--disable-rollback)

aws cloudformation deploy --stack-name "$PREFIX-webb" \
  --template-file webb.yaml \
  --capabilities CAPABILITY_IAM \
  ${ROLLBACK_FLAG[@]+"${ROLLBACK_FLAG[@]}"} \
  --parameter-overrides "Prefix=$PREFIX" "KeyName=$KEY_NAME" \
      "DataBucket=$DATA_BUCKET" "BackupBucket=$BACKUP_BUCKET" \
  --no-fail-on-empty-changeset --tags $TAGS

out() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}
WP_SECRET_ARN=$(out "$PREFIX-webb" WpAdminSecretArn)

echo ""
echo "============================================================"
echo " KLART! Hela stacken är utrullad som kod."
echo " Webbplats: $(out "$PREFIX-webb" WebsiteUrl)"
echo " Admin:     $(out "$PREFIX-webb" AdminUrl) (användare: novatrix_admin)"
echo ""
echo " Admin-lösenord (visas inte här):"
echo "   aws secretsmanager get-secret-value --secret-id $WP_SECRET_ARN --query SecretString --output text"
echo "============================================================"