#!/bin/bash
# Deployar novatrix-natverk -> novatrix-data -> novatrix-webb -> novatrix-skala (i den ordningen).
# Användning:  MY_IP=<din-IP>/32 KEY_NAME=novatrix-key bash deploy-all.sh
# Valfria miljövariabler: PREFIX, DB_CLASS, MIN_SIZE, MAX_SIZE, DESIRED, TARGET_CPU, INSTANCE_TYPE,
#                         DATA_BUCKET, BACKUP_BUCKET, NIGHT_SCHEDULE=true (färre servrar på natten),
#                         DISABLE_ROLLBACK=1 (felsökning)
set -euo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

PREFIX="${PREFIX:-novatrix}"
KEY_NAME="${KEY_NAME:-novatrix-key}"
DB_CLASS="${DB_CLASS:-db.t3.micro}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
MIN_SIZE="${MIN_SIZE:-2}"
MAX_SIZE="${MAX_SIZE:-4}"
DESIRED="${DESIRED:-2}"
TARGET_CPU="${TARGET_CPU:-50}"
NIGHT_SCHEDULE="${NIGHT_SCHEDULE:-false}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DATA_BUCKET="${DATA_BUCKET:-novatrix-data-$ACCOUNT_ID}"
BACKUP_BUCKET="${BACKUP_BUCKET:-novatrix-backup-$ACCOUNT_ID}"

if [ -z "${MY_IP:-}" ]; then
  MY_IP="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')/32"
fi
[[ "$MY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || { echo "FEL: ogiltig MY_IP: $MY_IP"; exit 1; }

echo "== Förkontroller"
for t in natverk data webb skala; do
  [ -f "$t.yaml" ] || { echo "FEL: $t.yaml saknas i $(pwd). data.yaml är oförändrad sedan v46: cp ../V46/data.yaml ."; exit 1; }
done
# Kontrollera att stackarna exporterar det skala.yaml importerar. Fångar t.ex. att v46-versionen av natverk.yaml eller
# webb.yaml kopierats av misstag (ett Fn::ImportValue-fel mitt i deployen säger inte vilken export som saknas).
for exp in AlbSgId PublicSubnetBId; do
  grep -q "natverk-$exp" natverk.yaml || { echo "FEL: natverk.yaml exporterar inte $exp (behövs av skala.yaml)"; exit 1; }
done
for exp in InstanceProfileArn WpAdminSecretArn WpSaltSecretArn; do
  grep -q "webb-$exp" webb.yaml || { echo "FEL: webb.yaml exporterar inte $exp (behövs av skala.yaml)"; exit 1; }
done
for exp in EfsId DbEndpoint DbName DbSecretArn; do
  grep -q "data-$exp" data.yaml || { echo "FEL: data.yaml exporterar inte $exp (behövs av skala.yaml)"; exit 1; }
done

aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null \
  || { echo "FEL: key pair '$KEY_NAME' saknas i $AWS_DEFAULT_REGION"; exit 1; }

ensure_bucket() {                              # buckets ligger utanför stackarna
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
for t in natverk data webb skala; do
  aws cloudformation validate-template --template-body "file://$t.yaml" >/dev/null
  echo "   OK $t.yaml"
done

TAGS="Project=$PREFIX ManagedBy=cloudformation"

echo "== 1/4 Stack $PREFIX-natverk"
aws cloudformation deploy --stack-name "$PREFIX-natverk" \
  --template-file natverk.yaml \
  --parameter-overrides "Prefix=$PREFIX" "MyIp=$MY_IP" \
  --no-fail-on-empty-changeset --tags $TAGS

echo "== 2/4 Stack $PREFIX-data (RDS tar ca 5-10 min)"
aws cloudformation deploy --stack-name "$PREFIX-data" \
  --template-file data.yaml \
  --parameter-overrides "Prefix=$PREFIX" "DbInstanceClass=$DB_CLASS" \
  --no-fail-on-empty-changeset --tags $TAGS

echo "== 3/4 Stack $PREFIX-webb (roll, instance profile, hemligheter)"
aws cloudformation deploy --stack-name "$PREFIX-webb" \
  --template-file webb.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides "Prefix=$PREFIX" "DataBucket=$DATA_BUCKET" "BackupBucket=$BACKUP_BUCKET" \
  --no-fail-on-empty-changeset --tags $TAGS

echo "== 4/4 Stack $PREFIX-skala (ALB + Auto Scaling; väntar på att servrarna installerat WordPress)"
# Vid felsökning: DISABLE_ROLLBACK=1 bash deploy-all.sh (stacken rullas då inte tillbaka, så man kan läsa loggarna)
ROLLBACK_FLAG=()
[ "${DISABLE_ROLLBACK:-0}" = "1" ] && ROLLBACK_FLAG=(--disable-rollback)

aws cloudformation deploy --stack-name "$PREFIX-skala" \
  --template-file skala.yaml \
  ${ROLLBACK_FLAG[@]+"${ROLLBACK_FLAG[@]}"} \
  --parameter-overrides "Prefix=$PREFIX" "KeyName=$KEY_NAME" "BackupBucket=$BACKUP_BUCKET" \
      "InstanceType=$INSTANCE_TYPE" "MinSize=$MIN_SIZE" "MaxSize=$MAX_SIZE" \
      "DesiredCapacity=$DESIRED" "TargetCpuUtilization=$TARGET_CPU" "EnableNightSchedule=$NIGHT_SCHEDULE" \
  --no-fail-on-empty-changeset --tags $TAGS

out() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}
TG_ARN=$(out "$PREFIX-skala" TargetGroupArn)
SITE_URL=$(out "$PREFIX-skala" SiteUrl)

echo "== Väntar på att $DESIRED servrar ska bli healthy i target groupen (max 10 min)"
for _ in $(seq 1 60); do
  HEALTHY=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
  echo "   healthy: $HEALTHY/$DESIRED"
  [ "$HEALTHY" -ge "$DESIRED" ] && break
  sleep 10
done

WP_SECRET_ARN=$(out "$PREFIX-webb" WpAdminSecretArn)
echo ""
echo "============================================================"
echo " KLART! Hela stacken är utrullad som kod, utan manuella steg."
echo " Webbplats: $SITE_URL"
echo " Admin:     ${SITE_URL}wp-admin  (användare: novatrix_admin)"
echo ""
echo " Admin-lösenord (visas inte här):"
echo "   aws secretsmanager get-secret-value --secret-id $WP_SECRET_ARN --query SecretString --output text"
echo ""
echo " Nästa: bash verify.sh   (sedan lasttest.sh och failover-test.sh)"
echo "============================================================"