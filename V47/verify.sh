#!/bin/bash
set -e
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
PREFIX="${PREFIX:-novatrix}"
cd "$(dirname "$0")"

echo "=========================================="
echo " V47 Verification"
echo "=========================================="

echo ""
echo "== 1. CloudFormation Stackar"
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?starts_with(StackName, '$PREFIX')].[StackName,StackStatus]" \
  --output table

echo ""
echo "== 2. Target Group Health (förväntar 2 healthy)"
TG_ARN=$(aws cloudformation describe-stacks --stack-name "$PREFIX-skala" \
  --query "Stacks[0].Outputs[?OutputKey=='TargetGroupArn'].OutputValue" --output text)
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query "TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Description]" \
  --output table

echo ""
echo "== 3. Auto Scaling Group (Min/Desired/Max)"
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$PREFIX-web-asg" \
  --query "AutoScalingGroups[0].[MinSize,DesiredCapacity,MaxSize]" --output text

echo ""
echo "== 4. Instanser och zoner (bevis på multi-AZ)"
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$PREFIX-web-asg" \
  --query "AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]" \
  --output table

echo ""
echo "== 5. Webbplatsen via ALB"
SITE_URL=$(aws cloudformation describe-stacks --stack-name "$PREFIX-skala" \
  --query "Stacks[0].Outputs[?OutputKey=='SiteUrl'].OutputValue" --output text)
echo "   URL: $SITE_URL"
HTTP_CODE=$(curl -s -L -o /dev/null --max-time 15 -w "%{http_code}" "$SITE_URL" 2>/dev/null || true)
if [[ "$HTTP_CODE" == 200* ]] || [[ "$HTTP_CODE" == 302* ]]; then
  echo "   OK: WordPress svarar med HTTP ${HTTP_CODE:0:3}"
else
  echo "   FEL: WordPress svarar inte (HTTP: $HTTP_CODE)."
fi

echo ""
echo "== 6. WordPress Admin-lösenord finns i Secrets Manager"
WP_SECRET=$(aws cloudformation describe-stacks --stack-name "$PREFIX-webb" \
  --query "Stacks[0].Outputs[?OutputKey=='WpAdminSecretArn'].OutputValue" --output text)
if aws secretsmanager describe-secret --secret-id "$WP_SECRET" >/dev/null 2>&1; then
  echo "   OK: Secret finns"
  echo "   Läs lösenordet med:"
  echo "   aws secretsmanager get-secret-value --secret-id $WP_SECRET --query SecretString --output text"
else
  echo "   FEL: hemligheten saknas"
fi

echo ""
echo "=========================================="
echo " Klart! Granska ovanstående utskrifter."
echo "=========================================="