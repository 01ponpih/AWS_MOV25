#!/bin/bash
set -eE
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"
load_ids

echo "== 1/3: DNS i $VPC_ID"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support   '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
echo "   DNS aktiverat."

echo "== 2/3: NACL-regler"
PUB_NACL_ID=$(lookup_nacl "$VPC_ID" "$PUB_NACL_NAME")
PRIV_NACL_ID=$(lookup_nacl "$VPC_ID" "$PRIV_NACL_NAME")

# Publik NACL: utgående mot databas och EFS
nacl_add "$PUB_NACL_ID" 140 egress  3306 3306  "$VPC_CIDR"
nacl_add "$PUB_NACL_ID" 150 egress  2049 2049  "$VPC_CIDR"

# Privat NACL: inkommande från webbserverns subnät för EFS
nacl_add "$PRIV_NACL_ID" 110 ingress 2049 2049 "10.0.1.0/24"

EPHEMERAL=$(aws ec2 describe-network-acls --network-acl-ids "$PUB_NACL_ID" \
  --query 'NetworkAcls[0].Entries[?Egress==`false` && RuleAction==`allow` && PortRange.From<=`1024` && PortRange.To>=`65535`] | length(@)' \
  --output text)
if [ "$EPHEMERAL" -eq 0 ]; then
  nacl_add "$PUB_NACL_ID" 160 ingress 1024 65535 "$VPC_CIDR"
else
  echo "   = ephemeral ingress finns redan på publik NACL"
fi

echo "== 3/3: NACL-tabeller"
echo "--- Publik ($PUB_NACL_NAME):"
aws ec2 describe-network-acls --network-acl-ids "$PUB_NACL_ID" \
  --query 'NetworkAcls[0].Entries[].[Egress,RuleNumber,RuleAction,PortRange.From,PortRange.To,CidrBlock]' \
  --output table
echo "--- Privat ($PRIV_NACL_NAME):"
aws ec2 describe-network-acls --network-acl-ids "$PRIV_NACL_ID" \
  --query 'NetworkAcls[0].Entries[].[Egress,RuleNumber,RuleAction,PortRange.From,PortRange.To,CidrBlock]' \
  --output table