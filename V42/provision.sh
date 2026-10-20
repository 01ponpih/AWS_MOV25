#!/bin/bash
set -e

# PARAMETRAR
PROJECT_NAME="novatrix-web-vg"
INSTANCE_TYPE="t3.micro"
KEY_NAME="novatrix-key"
SG_NAME="novatrix-sg-vg"
SG_DESC="Security group for Novatrix VG"

# Hämtar AMI automatiskt
AMI_ID="resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
echo "Hämtar din publika IP-adress..."
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')
echo "Din IP är: $MY_IP"

# 1. Kollar så att vi inte redan har en instans som körs
echo "Kontrollerar om instansen redan finns..."
EXISTING=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$PROJECT_NAME" "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [ "$EXISTING" != "None" ]; then
    echo "Fel: En instans med namnet $PROJECT_NAME finns redan ($EXISTING)."
    echo "Kör 'bash teardown.sh' först om du vill börja om från scratch."
    exit 1
fi

# 2. Key pair (skapar bara om den inte finns)
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    echo "Skapar key pair ($KEY_NAME)..."
    aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
    chmod 400 "${KEY_NAME}.pem"
else
    echo "Key pair $KEY_NAME finns redan."
fi

# 3. Säkerhetsgrupp (skapar bara om den inte finns)
echo "Kontrollerar säkerhetsgrupp ($SG_NAME)..."
SG_ID=$(aws ec2 describe-security-groups --group-names "$SG_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || aws ec2 create-security-group --group-name "$SG_NAME" --description "$SG_DESC" --query 'GroupId' --output text)

# 4. Öppna portar
echo "Konfigurerar portar i säkerhetsgruppen..."
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr ${MY_IP}/32 || echo "Varning: Port 22 kanske redan är öppen."
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 || echo "Varning: Port 80 kanske redan är öppen."

# 5. Startar instansen 
echo "Startar EC2-instans ($PROJECT_NAME)..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids $SG_ID \
  --user-data file://userdata.sh \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PROJECT_NAME}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instans skapad ($INSTANCE_ID). Väntar på start..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID
aws ec2 wait instance-status-ok --instance-ids $INSTANCE_ID

# Hämtar IP
IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo "====================================================="
echo "KLART! Instansen är igång."
echo "Surfa till: http://$IP"
echo "Verifiera med: curl http://$IP"
echo "====================================================="