#!/bin/bash
set -eE
export AWS_PAGER=""
export AWS_DEFAULT_REGION="eu-north-1"
cd "$(dirname "$0")"

trap 'echo "FEL på rad $LINENO."' ERR

KEY_NAME="novatrix-key"
INSTANCE_TYPE="t3.micro"
WEB_PROFILE="novatrix-web-role"

CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
if [[ "$CALLER_ARN" == *":root" ]]; then
  echo "FEL: Du kör som root. Använd din adminanvändare."; exit 1
fi

[ -f userdata.sh ] || { echo "FEL: userdata.sh saknas i $(pwd)."; exit 1; }

if ! aws iam get-instance-profile --instance-profile-name "$WEB_PROFILE" >/dev/null 2>&1; then
  echo "FEL: Instance profile $WEB_PROFILE saknas. Kör först: bash roller.sh"
  exit 1
fi

VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=novatrix-vpc --query 'Vpcs[0].VpcId' --output text)
[ "$VPC_ID" != "None" ] || { echo "FEL: novatrix-vpc saknas. Kör bash vpc.sh först."; exit 1; }

PUB_ID=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" Name=tag:Name,Values=novatrix-public --query 'Subnets[0].SubnetId' --output text)
sg() { aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$1" --query 'SecurityGroups[0].GroupId' --output text; }
BASTION_SG=$(sg novatrix-bastion-sg)
WEB_SG=$(sg novatrix-web-sg)

RUNNING=$(aws ec2 describe-instances --filters Name=vpc-id,Values="$VPC_ID" "Name=tag:Name,Values=novatrix-web,novatrix-bastion" Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$RUNNING" ]; then
  echo "FEL: Servrar finns redan ($RUNNING). Kör teardown-vpc.sh först."; exit 1
fi

KEY_FILE=""
for P in "./${KEY_NAME}.pem" "../V42/${KEY_NAME}.pem"; do
  if [ -f "$P" ]; then KEY_FILE="$P"; break; fi
done
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
  chmod 400 "${KEY_NAME}.pem"
  KEY_FILE="./${KEY_NAME}.pem"
  echo "Nytt nyckelpar skapat: $KEY_FILE"
elif [ -z "$KEY_FILE" ]; then
  echo "VARNING: Nyckelpar $KEY_NAME finns i AWS men ingen .pem hittades lokalt. SSH kommer inte fungera."
fi

# Hämta AMI med fallback
echo "Hämtar AMI-ID..."
AMI_ID=$(aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query "Parameters[0].Value" --output text 2>/dev/null || true)
if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ]; then
  echo "SSM misslyckades, söker direkt bland AMIs..."
  AMI_ID=$(aws ec2 describe-images --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*" "Name=architecture,Values=x86_64" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)
fi

if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ]; then
  echo "FEL: Kunde inte hitta något AMI. Kontrollera din region."
  exit 1
fi
echo "Använder AMI: $AMI_ID"

echo "Startar bastion och webbserver..."
BASTION_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" --subnet-id "$PUB_ID" --security-group-ids "$BASTION_SG" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=novatrix-bastion}]" \
  --query 'Instances[0].InstanceId' --output text)

WEB_ID=""
for i in 1 2 3 4 5 6; do
  WEB_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --subnet-id "$PUB_ID" --security-group-ids "$WEB_SG" \
    --iam-instance-profile Name="$WEB_PROFILE" --user-data file://userdata.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=novatrix-web}]" \
    --query 'Instances[0].InstanceId' --output text) && break
  echo "Profilen är inte klar än, försöker igen om 10 sekunder ($i/6)..."
  sleep 10
done
[ -n "$WEB_ID" ] || { echo "FEL: kunde inte starta webbservern."; exit 1; }

echo "Väntar på att instanserna ska bli klara..."
aws ec2 wait instance-status-ok --instance-ids "$BASTION_ID" "$WEB_ID"

ip() { aws ec2 describe-instances --instance-ids "$1" --query "Reservations[0].Instances[0].$2" --output text; }
echo "====================================================="
echo "Bastion: $(ip "$BASTION_ID" PublicIpAddress)"
echo "Webb:    http://$(ip "$WEB_ID" PublicIpAddress)  (privat IP $(ip "$WEB_ID" PrivateIpAddress))"
echo "Kör nu:  bash verify-net.sh ${KEY_FILE:-<sökväg-till-pem>}"
echo "====================================================="