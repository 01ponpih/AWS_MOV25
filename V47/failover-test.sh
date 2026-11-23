#!/bin/bash
# Failover-test: avslutar en server i gruppen medan en curl-loop mäter om sajten svarar via lastbalanseraren.
# Visar self-healing: gruppen startar en ersättare utan att någon gör något. Utskriften sparas i en textfil.
#
# Användning:  bash failover-test.sh        (valfria variabler: PREFIX, OUT)
set -uo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")" || exit 1

PREFIX="${PREFIX:-novatrix}"
ASG="$PREFIX-web-asg"
OUT="${OUT:-failover-$(date +%Y%m%d-%H%M%S).txt}"

SITE_URL=$(aws cloudformation describe-stacks --stack-name "$PREFIX-skala" \
  --query "Stacks[0].Outputs[?OutputKey=='SiteUrl'].OutputValue" --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names "$PREFIX-web-tg" --query 'TargetGroups[0].TargetGroupArn' --output text)
DESIRED=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].DesiredCapacity' --output text)

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT"; }
healthy_count() {
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text
}
show_instances() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --query 'AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]' --output table | tee -a "$OUT"
}

log "Sajt: $SITE_URL   Grupp: $ASG   Desired: $DESIRED   Healthy nu: $(healthy_count)"
log "Servrar före testet:"
show_instances

CODES=$(mktemp)
(
  while true; do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$SITE_URL" || true)
    echo "$(date +%H:%M:%S) $code" >> "$CODES"
    sleep 1
  done
) &
LOOP_PID=$!
trap 'kill "$LOOP_PID" 2>/dev/null || true; rm -f "$CODES"' EXIT INT TERM
sleep 5

VICTIM=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId | [0]" --output text)
VICTIM_AZ=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query "AutoScalingGroups[0].Instances[?InstanceId=='$VICTIM'].AvailabilityZone | [0]" --output text)
log "Avslutar server $VICTIM (zon $VICTIM_AZ). curl-loopen mäter sajten under tiden."
aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$VICTIM" \
  --no-should-decrement-desired-capacity >/dev/null

START=$SECONDS
RECOVERED=0
while [ $((SECONDS - START)) -lt 1500 ]; do
  H=$(healthy_count)
  log "healthy=$H/$DESIRED  (förfluten tid: $((SECONDS - START)) s)"
  if [ "$H" -ge "$DESIRED" ] && [ $((SECONDS - START)) -gt 30 ]; then RECOVERED=1; break; fi
  sleep 15
done
sleep 10
kill "$LOOP_PID" 2>/dev/null || true

if [ "$RECOVERED" = "1" ]; then
  log "Återhämtad: $DESIRED servrar är healthy igen efter $((SECONDS - START)) s, utan manuell handpåläggning."
else
  log "VARNING: gruppen blev inte healthy inom 25 min. Läs Reason: aws elbv2 describe-target-health --target-group-arn $TG_ARN"
fi

log "Servrar efter testet (ersättaren kan ligga i någon av zonerna):"
show_instances
log "Svarskoder från curl-loopen under hela testet (antal per kod):"
awk '{print $2}' "$CODES" | sort | uniq -c | tee -a "$OUT"
NON200=$(awk '$2 != "200"' "$CODES" | wc -l)
log "Anrop som inte gav 200: $NON200 av $(wc -l < "$CODES")"
if [ "$NON200" -gt 0 ]; then
  log "Tidpunkter för avvikande svar:"
  awk '$2 != "200"' "$CODES" | tee -a "$OUT"
fi
log "Skalningshändelser:"
aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG" --max-items 6 \
  --query 'Activities[].[StartTime,StatusCode,Description]' --output table | tee -a "$OUT"
log "Utskriften är sparad i $OUT"