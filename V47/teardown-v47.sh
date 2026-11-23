#!/bin/bash
# Rensar allt som deploy-all.sh skapat: stackarna i omvänd ordning (skala -> webb -> data -> natverk),
# därefter de två S3-buckets, och kontrollerar sist att inget som kostar pengar finns kvar.
# Skala-stacken först, annars startar gruppen nya servrar medan du river.
#
# Användning:  bash teardown-v47.sh
# Valfria variabler: YES=1 (hoppa över bekräftelsen), KEEP_BUCKETS=1 (behåll buckets), PREFIX
# Skriptet går att köra om om något fastnar: det hoppar över stackar som redan är borta.
set -uo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")" || exit 1

PREFIX="${PREFIX:-novatrix}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) || exit 1
DATA_BUCKET="${DATA_BUCKET:-novatrix-data-$ACCOUNT_ID}"
BACKUP_BUCKET="${BACKUP_BUCKET:-novatrix-backup-$ACCOUNT_ID}"

if [ "${YES:-0}" != "1" ]; then
  echo "VARNING: detta raderar stackarna $PREFIX-skala, $PREFIX-webb, $PREFIX-data och $PREFIX-natverk"
  echo "(inklusive databasen, utan slutsnapshot) och, om inte KEEP_BUCKETS=1, tömmer och tar bort"
  echo "$DATA_BUCKET och $BACKUP_BUCKET med alla backuper."
  read -r -p "Skriv 'radera' för att fortsätta: " ANS
  [ "$ANS" = "radera" ] || { echo "Avbryter."; exit 1; }
fi

stack_exists() {
  aws cloudformation describe-stacks --stack-name "$1" >/dev/null 2>&1
}

show_failures() {
  echo "   Resurser som misslyckades i $1:"
  aws cloudformation describe-stack-events --stack-name "$1" \
    --query "StackEvents[?contains(ResourceStatus, 'FAILED')].[LogicalResourceId,ResourceStatus,ResourceStatusReason]" \
    --output table 2>/dev/null | head -20
}

delete_stack() {
  local s=$1 attempt
  if ! stack_exists "$s"; then
    echo "   = $s finns inte"
    return 0
  fi
  for attempt in 1 2; do
    echo "   Tar bort $s (försök $attempt)..."
    aws cloudformation delete-stack --stack-name "$s"
    if aws cloudformation wait stack-delete-complete --stack-name "$s"; then
      echo "   OK: $s borttagen"
      return 0
    fi
    show_failures "$s"
    if [ "$attempt" = "1" ]; then
      echo "   Väntar 2 min och försöker igen (nätverkskort från lastbalanseraren släpps med fördröjning)..."
      sleep 120
    fi
  done
  echo "FEL: $s kunde inte tas bort. Åtgärda orsaken ovan och kör skriptet igen."
  return 1
}

echo "== Riv stackarna i omvänd ordning"
for s in "$PREFIX-skala" "$PREFIX-webb" "$PREFIX-data" "$PREFIX-natverk"; do
  delete_stack "$s" || exit 1
done

if [ "${KEEP_BUCKETS:-0}" = "1" ]; then
  echo "== S3-buckets lämnas kvar (KEEP_BUCKETS=1)"
else
  echo "== Tar bort S3-buckets (utanför stackarna)"
  for bucket in "$DATA_BUCKET" "$BACKUP_BUCKET"; do
    if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
      echo "   Tömmer och tar bort $bucket..."
      aws s3 rm "s3://$bucket" --recursive --only-show-errors
      aws s3api delete-bucket --bucket "$bucket"
    else
      echo "   = $bucket finns inte"
    fi
  done
fi

echo "== Kontrollerar att inget som kostar pengar finns kvar"
LEFT=0
check() {   # check <beskrivning> <kommandoutskrift>
  if [ -n "$2" ] && [ "$2" != "None" ]; then
    echo "   KVAR: $1: $2"
    LEFT=1
  else
    echo "   ok: inga $1"
  fi
}
check "lastbalanserare" "$(aws elbv2 describe-load-balancers --names "$PREFIX-alb" --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null)"
check "Auto Scaling-grupper" "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$PREFIX-web-asg" --query 'AutoScalingGroups[].AutoScalingGroupName' --output text 2>/dev/null)"
check "servrar" "$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$PREFIX-web" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)"
check "databaser" "$(aws rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier, '$PREFIX-data')].DBInstanceIdentifier" --output text 2>/dev/null)"
check "EFS-filsystem" "$(aws efs describe-file-systems --query "FileSystems[?Name=='$PREFIX-efs'].FileSystemId" --output text 2>/dev/null)"
if [ "${KEEP_BUCKETS:-0}" != "1" ]; then
  for bucket in "$DATA_BUCKET" "$BACKUP_BUCKET"; do
    aws s3api head-bucket --bucket "$bucket" 2>/dev/null && { echo "   KVAR: bucket $bucket"; LEFT=1; }
  done
fi

if [ "$LEFT" = "0" ]; then
  echo "Klart. Allt är borta (VPC, subnät, hemligheter och larm togs bort med stackarna)."
else
  echo "Något finns kvar, se ovan. Kör skriptet igen eller ta bort resursen i konsolen."
  exit 1
fi