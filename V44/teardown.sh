#!/bin/bash
export AWS_PAGER=""
export AWS_DEFAULT_REGION="eu-north-1"

echo "=== 1/2: Städar nätverk och servrar ==="
VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=novatrix-vpc \
  --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" = "None" ]; then 
  echo "Inget novatrix-vpc hittades."
else
  echo "Rensar $VPC_ID..."
  INSTANCES=$(aws ec2 describe-instances --filters Name=vpc-id,Values="$VPC_ID" \
    Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -n "$INSTANCES" ]; then
    aws ec2 terminate-instances --instance-ids $INSTANCES >/dev/null
    aws ec2 wait instance-terminated --instance-ids $INSTANCES
  fi

  for SG in novatrix-db-sg novatrix-web-sg novatrix-bastion-sg; do
    ID=$(aws ec2 describe-security-groups \
      --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$SG" \
      --query 'SecurityGroups[0].GroupId' --output text)
    if [ "$ID" != "None" ]; then aws ec2 delete-security-group --group-id "$ID"; fi
  done

  for S in $(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" \
    --query 'Subnets[].SubnetId' --output text); do
    aws ec2 delete-subnet --subnet-id "$S"
  done

  for N in $(aws ec2 describe-network-acls --filters Name=vpc-id,Values="$VPC_ID" \
    --query 'NetworkAcls[?IsDefault==`false`].NetworkAclId' --output text); do
    aws ec2 delete-network-acl --network-acl-id "$N"
  done

  for R in $(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC_ID" \
    --query 'RouteTables[?length(Associations[?Main==`true`])==`0`].RouteTableId' --output text); do
    aws ec2 delete-route-table --route-table-id "$R"
  done

  IGW=$(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values="$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)
  if [ "$IGW" != "None" ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID"
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"
  fi

  if aws ec2 delete-vpc --vpc-id "$VPC_ID"; then
    echo "Nätverket borttaget."
  else
    echo "VARNING: VPC:t kunde inte tas bort, se felet ovan."; exit 1
  fi
fi

echo ""
echo "=== 2/2: Städar IAM, buckets och användare ==="
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

echo ""
echo "====================================================="
echo "Allt städat! Du kan nu köra: bash deploy-all.sh"
echo "====================================================="