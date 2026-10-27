#!/bin/bash
export AWS_DEFAULT_REGION=eu-north-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
READ_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/novatrix-s3-read"
WEB_ROLE="novatrix-web-role"; LOG_ROLE="novatrix-logwriter-role"

ASSOC=$(aws ec2 describe-iam-instance-profile-associations \
  --filters "Name=state,Values=associated" \
  --query "IamInstanceProfileAssociations[?IamInstanceProfile.Arn=='arn:aws:iam::${ACCOUNT_ID}:instance-profile/${WEB_ROLE}'].AssociationId | [0]" --output text)
[ "$ASSOC" != "None" ] && aws ec2 disassociate-iam-instance-profile --association-id "$ASSOC"

aws iam remove-role-from-instance-profile --instance-profile-name $WEB_ROLE --role-name $WEB_ROLE || true
aws iam delete-instance-profile --instance-profile-name $WEB_ROLE || true
aws iam delete-role-policy --role-name $WEB_ROLE --policy-name assume-logwriter || true
aws iam detach-role-policy --role-name $WEB_ROLE --policy-arn $READ_ARN || true
aws iam delete-role --role-name $WEB_ROLE || true
aws iam delete-role-policy --role-name $LOG_ROLE --policy-name log-write || true
aws iam delete-role --role-name $LOG_ROLE || true

for U in ops-anna dev-erik; do
  aws iam delete-login-profile --user-name $U || true
done
aws iam remove-user-from-group --user-name ops-anna --group-name drift || true
aws iam remove-user-from-group --user-name dev-erik --group-name utveckling || true
aws iam delete-user --user-name ops-anna || true
aws iam delete-user --user-name dev-erik || true

aws iam detach-group-policy --group-name drift --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess || true
aws iam detach-group-policy --group-name utveckling --policy-arn $READ_ARN || true
aws iam delete-group --group-name drift || true
aws iam delete-group --group-name utveckling || true
aws iam delete-policy --policy-arn $READ_ARN || true

aws s3 rb "s3://novatrix-data-${ACCOUNT_ID}" --force || true
aws s3 rb "s3://novatrix-logs-${ACCOUNT_ID}" --force || true