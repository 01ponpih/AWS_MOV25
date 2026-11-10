#!/bin/bash
set -eE
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
export MSYS_NO_PATHCONV=1

REGION="$AWS_DEFAULT_REGION"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

VPC_NAME="novatrix-vpc"
PUB_SUBNET_NAME="novatrix-public"
PRIV_A_NAME="novatrix-private-a"
PRIV_B_NAME="novatrix-private-b"
WEB_SG_NAME="novatrix-web-sg"
BASTION_SG_NAME="novatrix-bastion-sg"
DB_SG_NAME="novatrix-db-sg"
PUB_NACL_NAME="novatrix-public-nacl"
PRIV_NACL_NAME="novatrix-private-nacl"
WEB_ROLE_NAME="novatrix-web-role"

DB_INSTANCE="novatrix-db"
DB_SUBNET_GROUP="novatrix-db-subnets"
DB_NAME="wordpress"
DB_USER="admin"
DB_ENGINE="mariadb"
DB_ENGINE_VERSION=""
DB_CLASS="db.t3.micro"
DB_STORAGE=20
DB_BACKUP_DAYS=1

EFS_NAME="novatrix-efs"
EFS_SG_NAME="novatrix-efs-sg"

BACKUP_BUCKET="novatrix-backup-${ACCOUNT_ID}"
SSM_PREFIX="/novatrix"

SECRETS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"

ensure_secrets() {
  if [ ! -f "$SECRETS_FILE" ]; then
    ( umask 077; {
        echo "# Genererad $(date -Is) - checka ALDRIG in"
        echo "DB_PASSWORD=$(openssl rand -hex 20)"
        echo "WP_ADMIN_PASSWORD=$(openssl rand -hex 16)"
      } > "$SECRETS_FILE" )
    chmod 600 "$SECRETS_FILE"
    echo "Skapade .env med slumpade lösenord."
  fi
  source "$SECRETS_FILE"
  local gi="$(dirname "$SECRETS_FILE")/.gitignore"
  touch "$gi"
  grep -qxF '.env' "$gi" || echo '.env' >> "$gi"
}

lookup_vpc() {
  local id
  id=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" \
    --query 'Vpcs[0].VpcId' --output text)
  [ "$id" != "None" ] && [ -n "$id" ] || { echo "FEL: VPC $VPC_NAME saknas." >&2; exit 1; }
  echo "$id"
}

lookup_subnet() {
  local vpc=$1 name=$2 id
  id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" \
    "Name=tag:Name,Values=$name" --query 'Subnets[0].SubnetId' --output text)
  [ "$id" != "None" ] && [ -n "$id" ] || { echo "FEL: Subnet $name saknas." >&2; exit 1; }
  echo "$id"
}

lookup_sg() {
  local vpc=$1 name=$2 id
  id=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" \
    "Name=group-name,Values=$name" --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" \
      "Name=tag:Name,Values=$name" --query 'SecurityGroups[0].GroupId' --output text)
  fi
  [ "$id" != "None" ] && [ -n "$id" ] || { echo "FEL: SG $name saknas." >&2; exit 1; }
  echo "$id"
}

lookup_nacl() {
  local vpc=$1 name=$2 id
  id=$(aws ec2 describe-network-acls \
    --filters "Name=vpc-id,Values=$vpc" "Name=tag:Name,Values=$name" \
    --query 'NetworkAcls[0].NetworkAclId' --output text)
  [ "$id" != "None" ] && [ -n "$id" ] || { echo "FEL: NACL $name saknas." >&2; exit 1; }
  echo "$id"
}

load_ids() {
  VPC_ID=$(lookup_vpc)
  VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text)
  PUB_SUBNET_ID=$(lookup_subnet "$VPC_ID" "$PUB_SUBNET_NAME")
  PRIV_A_SUBNET_ID=$(lookup_subnet "$VPC_ID" "$PRIV_A_NAME")
  PRIV_B_SUBNET_ID=$(lookup_subnet "$VPC_ID" "$PRIV_B_NAME")
  WEB_SG_ID=$(lookup_sg "$VPC_ID" "$WEB_SG_NAME")
  DB_SG_ID=$(lookup_sg "$VPC_ID" "$DB_SG_NAME")
}

nacl_add() {
  local nacl=$1 num=$2 dir=$3 from=$4 to=$5 cidr=$6 out
  local args=(--network-acl-id "$nacl" --rule-number "$num" --protocol tcp
              --port-range "From=$from,To=$to" --cidr-block "$cidr"
              --rule-action allow "--$dir")
  if out=$(aws ec2 create-network-acl-entry "${args[@]}" 2>&1); then
    echo "   + NACL-regel $num ($dir tcp/$from-$to mot $cidr)"
  elif [[ "$out" == *AlreadyExists* ]]; then
    aws ec2 replace-network-acl-entry "${args[@]}" >/dev/null
    echo "   ~ NACL-regel $num uppdaterad"
  else
    echo "   FEL vid NACL-regel $num: $out" >&2
    return 1
  fi
}

sg_allow() {
  local sg=$1 port=$2 source=$3 out
  if out=$(aws ec2 authorize-security-group-ingress --group-id "$sg" \
      --protocol tcp --port "$port" --source-group "$source" 2>&1); then
    echo "   + SG-regel ($sg <- $source :$port)"
  elif [[ "$out" == *Duplicate* ]]; then
    echo "   = SG-regel finns redan"
  else
    echo "   FEL vid SG-regel: $out" >&2
    return 1
  fi
}

ssm_put() {
  local name="$1"
  local value="$2"
  local type="${3:-String}"
  name="${name#/}"
  local full_path="/novatrix/${name}"
  
  MSYS_NO_PATHCONV=1 aws ssm put-parameter --name "$full_path" --value "$value" \
    --type "$type" --overwrite >/dev/null
  echo "   + SSM $full_path ($type)"
}