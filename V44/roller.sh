#!/bin/bash
set -e

export AWS_PAGER=""

# SÄKERHETSSPÄRR: Kör inte som root
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
if [[ "$CALLER_ARN" == *"root"* ]]; then
  echo "FEL: Du kör som root. Logga in som din admin-användare och kör igen."
  exit 1
fi

REGION="eu-north-1"
export AWS_DEFAULT_REGION="$REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

DATA_BUCKET="novatrix-data-${ACCOUNT_ID}"
LOG_BUCKET="novatrix-logs-${ACCOUNT_ID}"
WEB_ROLE="novatrix-web-role"
LOG_ROLE="novatrix-logwriter-role"
READ_POLICY="novatrix-s3-read"
INSTANCE_TAG="novatrix-web"
READ_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${READ_POLICY}"

echo "Konto-ID: $ACCOUNT_ID"
mkdir -p policies

cat > policies/trust-ec2.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

cat > policies/s3-read.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${DATA_BUCKET}" },
    { "Effect": "Allow", "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${DATA_BUCKET}/*" }
  ]
}
EOF

cat > policies/assume-logwriter.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "sts:AssumeRole",
    "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${LOG_ROLE}"
  }]
}
EOF

cat > policies/trust-web-role.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::${ACCOUNT_ID}:role/${WEB_ROLE}" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

cat > policies/log-write.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "s3:PutObject",
    "Resource": "arn:aws:s3:::${LOG_BUCKET}/*"
  }]
}
EOF

for B in "$DATA_BUCKET" "$LOG_BUCKET"; do
  if aws s3api head-bucket --bucket "$B" 2>/dev/null; then
    echo "Bucket $B finns redan."
  else
    aws s3api create-bucket --bucket "$B" --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
    aws s3api put-public-access-block --bucket "$B" --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  fi
done

echo "Testfil från Novatrix" > test.txt
aws s3 cp test.txt "s3://${DATA_BUCKET}/test.txt" >/dev/null
rm -f test.txt

for G in drift utveckling; do
  aws iam get-group --group-name "$G" >/dev/null 2>&1 || aws iam create-group --group-name "$G" >/dev/null
done

aws iam get-policy --policy-arn "$READ_ARN" >/dev/null 2>&1 || \
  aws iam create-policy --policy-name "$READ_POLICY" --policy-document file://policies/s3-read.json >/dev/null

aws iam attach-group-policy --group-name drift --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam attach-group-policy --group-name utveckling --policy-arn "$READ_ARN"

for U in ops-anna dev-erik; do
  aws iam get-user --user-name "$U" >/dev/null 2>&1 || aws iam create-user --user-name "$U" >/dev/null
done
aws iam add-user-to-group --user-name ops-anna --group-name drift
aws iam add-user-to-group --user-name dev-erik --group-name utveckling

for U in ops-anna dev-erik; do
  if ! aws iam get-login-profile --user-name "$U" >/dev/null 2>&1; then
    # Slumpar fram ett starkt lösenord
    PW="$(openssl rand -base64 12)Aa1!"
    aws iam create-login-profile --user-name "$U" --password "$PW" --no-password-reset-required >/dev/null
    echo "Lösenord för $U: $PW  (spara undan, visas bara nu)"
  fi
done

if ! aws iam get-role --role-name "$WEB_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$WEB_ROLE" --assume-role-policy-document file://policies/trust-ec2.json >/dev/null
fi
aws iam attach-role-policy --role-name "$WEB_ROLE" --policy-arn "$READ_ARN"
aws iam put-role-policy --role-name "$WEB_ROLE" --policy-name assume-logwriter --policy-document file://policies/assume-logwriter.json

echo "Väntar på att IAM ska sprida $WEB_ROLE så att Roll 2 kan skapas..."
for i in {1..10}; do
  if aws iam get-role --role-name "$WEB_ROLE" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
sleep 10 # Extra säkerhetsmarginal

if ! aws iam get-role --role-name "$LOG_ROLE" >/dev/null 2>&1; then
  for i in {1..6}; do
    if aws iam create-role --role-name "$LOG_ROLE" --assume-role-policy-document file://policies/trust-web-role.json >/dev/null 2>&1; then
      break
    fi
    echo "Försöker skapa Roll 2 igen ($i/6)..."
    sleep 10
  done
fi
aws iam put-role-policy --role-name "$LOG_ROLE" --policy-name log-write --policy-document file://policies/log-write.json

if ! aws iam get-instance-profile --instance-profile-name "$WEB_ROLE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$WEB_ROLE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$WEB_ROLE" --role-name "$WEB_ROLE"
fi

echo "Väntar 15 sekunder på att IAM ska sprida ändringarna..."
sleep 15

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_TAG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [ "$INSTANCE_ID" = "None" ]; then
  echo "Ingen körande instans '$INSTANCE_TAG' än. Profilen kopplas när servers.sh startar webbservern."
else
  EXISTING=$(aws ec2 describe-iam-instance-profile-associations \
    --filters "Name=instance-id,Values=$INSTANCE_ID" "Name=state,Values=associated" \
    --query 'IamInstanceProfileAssociations[0].AssociationId' --output text)

  OK=0
  for i in 1 2 3 4 5 6; do
    if [ "$EXISTING" = "None" ]; then
      aws ec2 associate-iam-instance-profile --instance-id "$INSTANCE_ID" --iam-instance-profile Name="$WEB_ROLE" >/dev/null && OK=1 && break
    else
      aws ec2 replace-iam-instance-profile-association --association-id "$EXISTING" --iam-instance-profile Name="$WEB_ROLE" >/dev/null && OK=1 && break
    fi
    echo "Profilen är inte klar än, försöker igen om 10 sekunder ($i/6)..."
    sleep 10
  done

  if [ "$OK" = "1" ]; then
    echo "Profilen kopplad till $INSTANCE_ID"
  else
    echo "FEL: Kunde inte koppla profilen. Gör det i EC2: Actions, Security, Modify IAM role."
    exit 1
  fi
fi

echo "====================================================="
echo "Klart! Data-bucket: $DATA_BUCKET  Logg-bucket: $LOG_BUCKET"
echo "====================================================="