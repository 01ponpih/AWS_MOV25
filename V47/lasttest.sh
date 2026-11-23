#!/bin/bash
# Lasttest: skapar last och visar hur Auto Scaling-gruppen skalar ut. Utskriften sparas i en textfil (bevis).
#
# Två lägen:
#   MODE=cpu   (rekommenderas) Startar två "yes"-processer på varje server via SSH. CPU stannar högt så länge testet
#              körs, så utskalningen syns säkert. Kräver KEY_FILE och att din IP finns i MyIp.
#   MODE=http  (standard) Parallella curl-klienter mot lastbalanseraren, som riktiga besökare. Ingen SSH behövs,
#              men det är inte säkert att CPU når målet (höj CONCURRENCY vid behov).
#
# Användning:  MODE=cpu KEY_FILE=~/.ssh/novatrix-key.pem bash lasttest.sh
# Valfria variabler: DURATION (sek med last, standard 900), CONCURRENCY (http-läge, standard 8),
#                    COOLDOWN (sek att observera efter lasten, standard 0; inskalning tar ca 15-20 min), PREFIX, OUT
# Tips: kör på din egen dator, eller håll CloudShell-fliken aktiv (CloudShell stänger sessionen efter ~20-30 min utan aktivitet).
set -uo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")" || exit 1

PREFIX="${PREFIX:-novatrix}"
ASG="$PREFIX-web-asg"
MODE="${MODE:-http}"
KEY_FILE="${KEY_FILE:-}"
DURATION="${DURATION:-900}"
CONCURRENCY="${CONCURRENCY:-8}"
COOLDOWN="${COOLDOWN:-0}"
OUT="${OUT:-lasttest-$(date +%Y%m%d-%H%M%S).txt}"

SITE_URL=$(aws cloudformation describe-stacks --stack-name "$PREFIX-skala" \
  --query "Stacks[0].Outputs[?OutputKey=='SiteUrl'].OutputValue" --output text)
URL="${SITE_URL%/}"
TG_ARN=$(aws elbv2 describe-target-groups --names "$PREFIX-web-tg" --query 'TargetGroups[0].TargetGroupArn' --output text)

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT"; }

cpu_avg() {
  local v
  v=$(aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization \
    --dimensions Name=AutoScalingGroupName,Value="$ASG" \
    --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period 60 --statistics Average \
    --query 'sort_by(Datapoints,&Timestamp)[-1].Average' --output text 2>/dev/null || echo None)
  if [ -z "$v" ] || [ "$v" = "None" ]; then echo "-"; else printf '%.0f' "$v"; fi
}

PIDS=()
trap '[ "${#PIDS[@]}" -gt 0 ] && kill "${PIDS[@]}" 2>/dev/null || true' EXIT INT TERM

log "Start: läge $MODE, $DURATION s (grupp: $ASG, sajt: $URL)"
log "Före lasten (min, desired, max):"
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].[MinSize,DesiredCapacity,MaxSize]' --output text | tee -a "$OUT"

if [ "$MODE" = "cpu" ]; then
  [ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ] || { echo "FEL: MODE=cpu kräver KEY_FILE=~/.ssh/<nyckel>.pem"; exit 1; }
  IPS=$(aws ec2 describe-instances \
    --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].PublicIpAddress' --output text)
  for ip in $IPS; do
    log "Startar CPU-last på $ip (2 processer, $DURATION s)"
    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "ec2-user@$ip" \
      "for n in 1 2; do nohup timeout ${DURATION}s yes > /dev/null 2>&1 < /dev/null & done" \
      || log "VARNING: kunde inte ansluta till $ip (är din IP rätt i MyIp?)"
  done
else
  for _ in $(seq 1 "$CONCURRENCY"); do
    (
      end=$((SECONDS + DURATION))
      while [ "$SECONDS" -lt "$end" ]; do
        curl -s -o /dev/null -m 20 "$URL/?s=lasttest$RANDOM" || true     # sökning kostar CPU i PHP och databasen
      done
    ) &
    PIDS+=($!)
  done
fi

STOP=$((SECONDS + DURATION + COOLDOWN))
while [ "$SECONDS" -lt "$STOP" ]; do
  STATE=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --query 'AutoScalingGroups[0].[DesiredCapacity,length(Instances[?LifecycleState==`InService`])]' --output text)
  HEALTHY=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
  # shellcheck disable=SC2086
  set -- $STATE
  log "CPU(medel)=$(cpu_avg)%  desired=$1  inService=$2  healthy=$HEALTHY"
  sleep 30
done

log "Klart. Senaste skalningshändelser:"
aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG" --max-items 8 \
  --query 'Activities[].[StartTime,StatusCode,Description]' --output table | tee -a "$OUT"
log "Lasten är slut. Gruppen skalar in efter ca 15-20 min (larmet AlarmLow kräver lång tid under målet)."
log "Utskriften är sparad i $OUT"