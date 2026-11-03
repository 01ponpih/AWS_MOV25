#!/bin/bash
set -eE
export AWS_PAGER=""
export AWS_DEFAULT_REGION="eu-north-1"
cd "$(dirname "$0")"

trap 'echo "FEL på rad $LINENO. Kör bash teardown-vpc.sh innan du försöker igen."' ERR

AZ_A="eu-north-1a"
AZ_B="eu-north-1b"

CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
if [[ "$CALLER_ARN" == *":root" ]]; then
  echo "FEL: Du kör som root. Använd din adminanvändare."; exit 1
fi

EXISTING_VPC=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=novatrix-vpc \
  --query 'Vpcs[0].VpcId' --output text)
if [ "$EXISTING_VPC" != "None" ]; then
  echo "FEL: novatrix-vpc finns redan ($EXISTING_VPC). Kör teardown-vpc.sh först."
  exit 1
fi

MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')
echo "Min IP: $MY_IP"

tag() { aws ec2 create-tags --resources "$1" --tags Key=Name,Value="$2"; }
acl() {
  aws ec2 create-network-acl-entry --network-acl-id "$1" --rule-number "$2" --"$3" \
    --protocol tcp --port-range From="$5",To="$6" --cidr-block "$4" --rule-action allow
}
use_nacl() {
  ASSOC=$(aws ec2 describe-network-acls --filters Name=association.subnet-id,Values="$1" \
    --query "NetworkAcls[0].Associations[?SubnetId=='$1'].NetworkAclAssociationId" --output text)
  aws ec2 replace-network-acl-association --association-id "$ASSOC" --network-acl-id "$2" >/dev/null
}

echo "Skapar VPC och subnät..."
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query Vpc.VpcId --output text)
tag "$VPC_ID" novatrix-vpc

mk_subnet() { aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$1" \
  --availability-zone "$2" --query Subnet.SubnetId --output text; }
PUB_ID=$(mk_subnet 10.0.1.0/24 "$AZ_A");  tag "$PUB_ID" novatrix-public
PRIV_A=$(mk_subnet 10.0.2.0/24 "$AZ_A");  tag "$PRIV_A" novatrix-private-a
PRIV_B=$(mk_subnet 10.0.4.0/24 "$AZ_B");  tag "$PRIV_B" novatrix-private-b
aws ec2 modify-subnet-attribute --subnet-id "$PUB_ID" --map-public-ip-on-launch

echo "Skapar gateway och routing..."
IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)
tag "$IGW_ID" novatrix-igw
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

PUB_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query RouteTable.RouteTableId --output text)
tag "$PUB_RT" novatrix-public-rt
aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_ID" >/dev/null

PRIV_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query RouteTable.RouteTableId --output text)
tag "$PRIV_RT" novatrix-private-rt
aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_A" >/dev/null
aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_B" >/dev/null

echo "Skapar security groups..."
mk_sg() { aws ec2 create-security-group --group-name "$1" --description "$2" \
  --vpc-id "$VPC_ID" --query GroupId --output text; }
BASTION_SG=$(mk_sg novatrix-bastion-sg "SSH fran admin-IP")
WEB_SG=$(mk_sg novatrix-web-sg "Webb och SSH fran bastion")
DB_SG=$(mk_sg novatrix-db-sg "Databas fran webben")

aws ec2 authorize-security-group-ingress --group-id "$BASTION_SG" --protocol tcp --port 22 --cidr "${MY_IP}/32" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$WEB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$WEB_SG" --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$WEB_SG" --protocol tcp --port 22 --source-group "$BASTION_SG" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$DB_SG" --protocol tcp --port 3306 --source-group "$WEB_SG" >/dev/null

echo "Skapar network ACL:er..."
PUB_NACL=$(aws ec2 create-network-acl --vpc-id "$VPC_ID" --query NetworkAcl.NetworkAclId --output text)
tag "$PUB_NACL" novatrix-public-nacl
acl "$PUB_NACL" 100 ingress 0.0.0.0/0 80 80
acl "$PUB_NACL" 110 ingress 0.0.0.0/0 443 443
acl "$PUB_NACL" 120 ingress "${MY_IP}/32" 22 22
acl "$PUB_NACL" 130 ingress 0.0.0.0/0 1024 65535
acl "$PUB_NACL" 100 egress  0.0.0.0/0 80 80
acl "$PUB_NACL" 110 egress  0.0.0.0/0 443 443
acl "$PUB_NACL" 120 egress  0.0.0.0/0 1024 65535
acl "$PUB_NACL" 130 egress  10.0.2.0/24 3306 3306
acl "$PUB_NACL" 140 egress  10.0.4.0/24 3306 3306
use_nacl "$PUB_ID" "$PUB_NACL"

PRIV_NACL=$(aws ec2 create-network-acl --vpc-id "$VPC_ID" --query NetworkAcl.NetworkAclId --output text)
tag "$PRIV_NACL" novatrix-private-nacl
acl "$PRIV_NACL" 100 ingress 10.0.1.0/24 3306 3306
acl "$PRIV_NACL" 100 egress  10.0.1.0/24 1024 65535
use_nacl "$PRIV_A" "$PRIV_NACL"
use_nacl "$PRIV_B" "$PRIV_NACL"

echo "====================================================="
echo "Nätverket är klart: $VPC_ID"
echo "Nästa steg: identitet (V43/roller.sh), sedan servrar (V44/servers.sh)."
echo "====================================================="