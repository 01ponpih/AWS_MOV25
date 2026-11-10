# AWS Uppgift 4 (v45) - Storage och databas

**Namn:** Pontus Pihlström
**Kurs:** AWS, MOV25
**Datum:** 2026-11-10
**GitHub-repo:** https://github.com/01ponpih/AWS_MOV25

## Sammanfattning
Novatrix WordPress-stack är nu komplett. En EC2-instans i ett publikt subnät kör WordPress, som är kopplat mot en privat RDS MariaDB-databas och ett EFS-filsystem för delad lagring. En automatisk backup av databasen läggs i en privat S3-bucket som raderas automatiskt efter 14 dagar via en livscykelregel. RDS har automatisk backup aktiverad (1 dag, vilket är Free Tier-gränsen). Hela miljön provisioneras med bash-skript.

## Arkitektur
```text
   Internet ── HTTP 80 ──┐          ┌── SSH 22 (din IP)
                         ▼          ▼
PUBLIKT SUBNÄT   [ Webbserver ] ◄─SSH─ [ Bastion ]
10.0.1.0/24        │    │    └── HTTPS 443 ──► S3 (backup/, 14 d) + SSM
                   │    │
             3306 SSL  2049 TLS
                   ▼    ▼
PRIVATA SUBNÄT   [ RDS ]  [ EFS mount targets ]
10.0.2.0/24 + 10.0.4.0/24
```

## Lösningen i korthet
*   **Nätverk:** Webbservern körs publikt. RDS och EFS ligger i privata subnät utan väg ut till internet.
*   **Databas:** RDS MariaDB (`db.t3.micro`, Single-AZ) med `Publicly Accessible: False`.
*   **Lagring:** EFS används för `/var/www/html/wp-content` för att ge delad och beständig lagring som överlever att servern byts ut. S3 används för databas-backuper.
*   **WordPress:** Installerat via skript. Databasuppgifter hämtas säkert från SSM Parameter Store.

---

## Delmoment 1: Repo
Mappen `V45` är skapad i kursrepot och rotens `README.md` har uppdaterats. Skripten bygger vidare på nätverket och servrarna från V42–V44.

## Delmoment 2-5: Uppsättning och funktion
![WordPress startsida](<Skärmbild 2026-11-10 144447.png>)
![Mediabibliotek med uppladdad bild](<Skärmbild 2026-11-10 143542.png>)

WordPress installerades via `setup-wordpress.sh`. EFS monterades med `amazon-efs-utils` och TLS. Databasen skapades med `aws rds create-db-instance`. Ett cronjobb (`/etc/cron.d/novatrix-backup`) dumpar databasen dagligen och laddar upp den till S3.

## Delmoment 6: Säkerhet i lager (Defense in Depth)
Säkerheten är uppdelad i flera lager för att skydda data:
1.  **Nätverk:** Databasen och EFS ligger i privata subnät. SSH till webbservern sker via bastionen.
2.  **Security Groups:** `novatrix-db-sg` tillåter bara 3306 från `novatrix-web-sg`. `novatrix-efs-sg` tillåter bara 2049 från `novatrix-web-sg`.
3.  **Network ACL:** Den privata NACL:en (`novatrix-private-nacl`) är ett riktigt lager. Den släpper bara in 3306 och 2049 från det publika subnätet (10.0.1.0/24), och släpper bara ut returtrafik (1024–65535) tillbaka dit. Den publika NACL:en har regler för 3306 och 2049 för att dokumentera avsikten.
4.  **IAM (Least Privilege):** Webbserverns roll får bara skriva (`PutObject`) till S3-backupen, kan inte lista eller läsa den, och läser dessutom sin egen konfiguration i SSM. Den har även läsrätt på `novatrix-data`-bucketen från v43.
5.  **Hemligheter:** Slumpade lösenord i `.env` (gitignorerad) och SSM `SecureString`. `wp-config.php` är `root:apache 640`.
6.  **Dataskydd S3:** Block public access, SSE-kryptering (AES256) och bucketpolicy som nekar icke-TLS.
7.  **Applikation:** WordPress använder `DISALLOW_FILE_EDIT`, Apache kör `ServerTokens Prod`, och admin-användaren heter `novatrix_admin` (inte "admin").
8.  **Kryptering:** RDS är krypterad i vila, EFS-policy kräver TLS, S3-policy nekar icke-TLS, och WordPress ansluter till RDS med krypterad anslutning (SSL, `MYSQLI_CLIENT_SSL`).

---

## Delmoment 7: Verifiering (Bevis)
*Notera: Skripten justerades efter första körningen (unika salts, flytt av v44-index.html, filrättigheter). Bevisen nedan kommer från första körningen.*

**1. RDS och S3 (utdrag från `verify.sh`)**
```text
========== RDS ==========
|  BackupDays|  1                                                       |
|  Class     |  db.t3.micro                                             |
|  Encrypted |  True                                                    |
|  Public    |  False                                                   |
|  Status    |  available                                               |

========== S3 ==========
| ExpiresAfterDays  |           ID             | Prefix   | Status   |
|  14               |  expire-backups-14-days  |  backup/ |  Enabled |
|  BlockPublicAcls  |  True |
|  BlockPublicPolicy|  True |
```

**2. Säkerhet (utdrag från `verify.sh`)**
*Källa: `sg-05090495748437905` är `novatrix-web-sg`.*
```text
--- db-sg:
|  3306|  3306 |  sg-05090495748437905  |
--- efs-sg:
|  2049|  2049 |  sg-05090495748437905  |
--- Privat NACL (från deploy-utskrift):
|  True |  100   |  allow |  1024 |  65535 |  10.0.1.0/24   |
|  False|  100   |  allow |  3306 |  3306  |  10.0.1.0/24   |
|  False|  110   |  allow |  2049 |  2049  |  10.0.1.0/24   |
```

**3. Backup-fil i S3**
```text
$ aws s3 ls s3://novatrix-backup-373117960549/backup/
2026-11-10 14:34:47     139227 wordpress-20261110-133446.sql.gz
```

**4. Automatisk cron-backup på servern**
```text
$ cat /etc/cron.d/novatrix-backup
0 2 * * * root /usr/local/bin/novatrix-backup.sh >> /var/log/novatrix-backup.log 2>&1

$ systemctl is-active crond
active
```

**5. Databasen (WordPress-tabeller via SSL)**
```text
$ mysql --ssl -h novatrix-db... -u admin wordpress -e "SHOW TABLES;"
+-----------------------+
| Tables_in_wordpress   |
+-----------------------+
| wp_commentmeta        |
| wp_comments           |
| wp_links              |
| wp_options            |
| wp_postmeta           |
| wp_posts              |
| wp_term_relationships |
| wp_term_taxonomy      |
| wp_termmeta           |
| wp_terms              |
| wp_usermeta           |
| wp_users              |
+-----------------------+
```

**6. EFS-montering och WordPress-filer**
```text
$ df -hT /var/www/html/wp-content
Filesystem     Type  Size  Used Avail Use% Mounted on
127.0.0.1:/    nfs4  8.0E     0  8.0E   0% /var/www/html/wp-content

$ sudo ls -la /var/www/html/wp-content/uploads/2026/11/
-rw-r--r--. 1 apache apache 486858 Nov 10 13:32 Skärmbild-2026-09-29-125216.png
```
*(Notera att `127.0.0.1` är `amazon-efs-utils` inbyggda TLS-tunnel (stunnel), vilket bevisar att trafiken är krypterad).*

**7. IAM Least Privilege (S3 Access Denied)**
```text
$ aws s3 ls s3://novatrix-backup-373117960549/backup/
aws: [ERROR]: An error occurred (AccessDenied) when calling the ListObjectsV2 operation: User: arn:aws:sts::373117960549:assumed-role/novatrix-web-role/... is not authorized to perform: s3:ListBucket...
```

**8. Kontroll av wp-config (SSL och säkerhet)**
```text
$ sudo grep -E "DB_HOST|MYSQL_CLIENT_FLAGS|DISALLOW_FILE_EDIT" /var/www/html/wp-config.php
define( 'DB_HOST', 'novatrix-db.cjwqgcgoc96y.eu-north-1.rds.amazonaws.com' );
define( 'DISALLOW_FILE_EDIT', true );
define( 'MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL );
```

**9. Databasen är inte nåbar utifrån (från egen dator)**
```powershell
PS C:\> Test-NetConnection novatrix-db.cjwqgcgoc96y.eu-north-1.rds.amazonaws.com -Port 3306
WARNING: TCP connect to (10.0.2.73 : 3306) failed
WARNING: Ping to 10.0.2.73 failed with status: TimedOut

ComputerName     : novatrix-db.cjwqgcgoc96y.eu-north-1.rds.amazonaws.com
RemoteAddress    : 10.0.2.73
RemotePort       : 3306
InterfaceAlias   : vEthernet (WAN)
SourceAddress    : 192.168.1.113
PingSucceeded    : False
PingReplyDetails (RTT) : 0 ms
TcpTestSucceeded : False
```

---

## VG: Motiveringar och nivåval

**Databas (RDS):**
*   **Instansklass:** Valde `db.t3.micro` för att den ingår i Free Tier och klarar en labbmiljö.
*   **Single-AZ:** Multi-AZ dubblar kostnaden. För en kurslabb räcker Single-AZ, men i produktion hade Multi-AZ valts för hög tillgänglighet.
*   **Backup-retention:** Använder 1 dag (Free Tier-gräns). **I drift hade jag valt 7 dagar** för att få en veckas point-in-time-recovery (PITR) och hinna upptäcka felaktig data innan den skrivs över.

**Lagring (EFS vs S3):**
*   **EFS:** Används för `wp-content` för att ge delad och beständig lagring som överlever att servern byts ut, samt förbereder för horisontell skalning (flera webbservrar kan montera samma EFS).
*   **S3:** Används för backuper. Det är cirka 10 gånger billigare per GB än EFS och livscykelregeln sköter städningen automatiskt.

**Övriga val:**
*   **SSM Parameter Store:** Används som hemlighetslager för att skicka DB-lösenordet till servern utan att det hamnar i GitHub eller i skripten.
*   **HTTP vs HTTPS:** Sidan körs på HTTP. I produktion hade nästa steg varit att sätta upp en domän, ACM-certifikat och en Application Load Balancer för att tvinga HTTPS.

## Så återskapas lösningen
*Förutsätter att V44 (bash deploy-all.sh) har körts först.*
```bash
# Bygger nätverk, databas, EFS, S3 och installerar WordPress
bash deploy.sh
```

## Städning
```bash
bash teardown-v45.sh
```

## Bilaga: Skript

Nedan följer de fullständiga skript som användes för att bygga, verifiera och riva miljön.

### `config.sh`
```bash
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
```

### `01-network.sh`
```bash
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
```

### `02-database.sh`
```bash
#!/bin/bash
set -eE
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"
ensure_secrets
load_ids

echo "== 1/5: Öppnar 3306 i $DB_SG_NAME från $WEB_SG_NAME"
sg_allow "$DB_SG_ID" 3306 "$WEB_SG_ID"

echo "== 2/5: DB subnet group"
if aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
  echo "   = finns redan"
else
  aws rds create-db-subnet-group \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "Novatrix privata subnat for RDS" \
    --subnet-ids "$PRIV_A_SUBNET_ID" "$PRIV_B_SUBNET_ID" \
    --tags Key=Name,Value="$DB_SUBNET_GROUP" >/dev/null
  echo "   + skapad"
fi

echo "== 3/5: RDS-instans $DB_INSTANCE"
if aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" >/dev/null 2>&1; then
  echo "   = finns redan"
else
  ENGINE_ARGS=()
  [ -n "$DB_ENGINE_VERSION" ] && ENGINE_ARGS=(--engine-version "$DB_ENGINE_VERSION")

  aws rds create-db-instance \
    --db-instance-identifier "$DB_INSTANCE" \
    --engine "$DB_ENGINE" \
    "${ENGINE_ARGS[@]}" \
    --db-instance-class "$DB_CLASS" \
    --allocated-storage "$DB_STORAGE" \
    --storage-type gp2 \
    --storage-encrypted \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASSWORD" \
    --db-name "$DB_NAME" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --vpc-security-group-ids "$DB_SG_ID" \
    --no-publicly-accessible \
    --no-multi-az \
    --backup-retention-period "$DB_BACKUP_DAYS" \
    --copy-tags-to-snapshot \
    --tags Key=Name,Value="$DB_INSTANCE" >/dev/null
  echo "   + skapad"
fi

echo "== 4/5: Väntar på att RDS blir tillgänglig (5-10 min)..."
aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE"
DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "   Endpoint: $DB_ENDPOINT"

echo "== 5/5: Sparar konfiguration i SSM"
ssm_put db-endpoint "$DB_ENDPOINT"
ssm_put db-name "$DB_NAME"
ssm_put db-user "$DB_USER"
ssm_put db-password "$DB_PASSWORD" SecureString
ssm_put wp-admin-password "$WP_ADMIN_PASSWORD" SecureString

aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].[DBInstanceStatus,PubliclyAccessible,BackupRetentionPeriod,EngineVersion]' \
  --output table
```

### `03-storage.sh`
```bash
#!/bin/bash
set -eE
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"
load_ids

echo "== 1/6: Security group $EFS_SG_NAME"
EFS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$EFS_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$EFS_SG_ID" = "None" ] || [ -z "$EFS_SG_ID" ]; then
  EFS_SG_ID=$(aws ec2 create-security-group \
    --group-name "$EFS_SG_NAME" --description "Novatrix EFS NFS" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$EFS_SG_NAME}]" \
    --query GroupId --output text)
  echo "   + skapad: $EFS_SG_ID"
else
  echo "   = finns redan"
fi
sg_allow "$EFS_SG_ID" 2049 "$WEB_SG_ID"

echo "== 2/6: Filsystem $EFS_NAME"
EFS_ID=$(aws efs describe-file-systems --creation-token "$EFS_NAME" \
  --query 'FileSystems[0].FileSystemId' --output text 2>/dev/null || true)
if [ "$EFS_ID" = "None" ] || [ -z "$EFS_ID" ]; then
  EFS_ID=$(aws efs create-file-system --creation-token "$EFS_NAME" \
    --performance-mode generalPurpose --throughput-mode bursting --encrypted \
    --tags Key=Name,Value="$EFS_NAME" --query FileSystemId --output text)
  echo "   + skapad: $EFS_ID"
else
  echo "   = finns redan"
fi
until [ "$(aws efs describe-file-systems --file-system-id "$EFS_ID" \
  --query 'FileSystems[0].LifeCycleState' --output text)" = "available" ]; do sleep 5; done

echo "== 3/6: Mount targets"
for SUBNET in "$PRIV_A_SUBNET_ID" "$PRIV_B_SUBNET_ID"; do
  EXIST=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
    --query "MountTargets[?SubnetId=='$SUBNET'].MountTargetId" --output text)
  if [ -z "$EXIST" ]; then
    aws efs create-mount-target --file-system-id "$EFS_ID" \
      --subnet-id "$SUBNET" --security-groups "$EFS_SG_ID" >/dev/null
    echo "   + mount target i $SUBNET"
  else
    echo "   = finns redan i $SUBNET"
  fi
done
until [ -z "$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
  --query 'MountTargets[?LifeCycleState!=`available`].MountTargetId' --output text)" ]; do sleep 5; done

echo "== 4/6: Livscykel (IA 30 dagar) + TLS-policy"
aws efs put-lifecycle-configuration --file-system-id "$EFS_ID" \
  --lifecycle-policies TransitionToIA=AFTER_30_DAYS >/dev/null

POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowMount",
      "Effect": "Allow",
      "Principal": {"AWS": "*"},
      "Action": ["elasticfilesystem:ClientMount","elasticfilesystem:ClientWrite","elasticfilesystem:ClientRootAccess"],
      "Resource": "arn:aws:elasticfilesystem:${REGION}:${ACCOUNT_ID}:file-system/${EFS_ID}"
    },
    {
      "Sid": "DenyUnencryptedTransport",
      "Effect": "Deny",
      "Principal": {"AWS": "*"},
      "Action": "*",
      "Resource": "arn:aws:elasticfilesystem:${REGION}:${ACCOUNT_ID}:file-system/${EFS_ID}",
      "Condition": {"Bool": {"aws:SecureTransport": "false"}}
    }
  ]
}
EOF
)
aws efs put-file-system-policy --file-system-id "$EFS_ID" --policy "$POLICY" >/dev/null
echo "   + policy satt"

echo "== 5/6: Sparar EFS-ID i SSM"
ssm_put efs-id "$EFS_ID"

echo "== 6/6: AZ-kontroll"
WEB_AZ=$(aws ec2 describe-subnets --subnet-ids "$PUB_SUBNET_ID" \
  --query 'Subnets[0].AvailabilityZone' --output text)
MT_AZS=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
  --query 'MountTargets[].AvailabilityZoneName' --output text)
if [[ "$MT_AZS" == *"$WEB_AZ"* ]]; then
  echo "   OK: mount target i $WEB_AZ finns"
else
  echo "   VARNING: webbservern ligger i $WEB_AZ, men mount targets finns bara i: $MT_AZS"
fi

echo ""
echo "EFS-ID: $EFS_ID"
```

### `04-s3-backup.sh`
```bash
#!/bin/bash
set -eE
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"

echo "== 1/4: Bucket $BACKUP_BUCKET"
if aws s3api head-bucket --bucket "$BACKUP_BUCKET" 2>/dev/null; then
  echo "   = finns redan"
else
  aws s3api create-bucket --bucket "$BACKUP_BUCKET" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  echo "   + skapad"
fi

echo "== 2/4: Härdning (block public, kryptering, TLS)"
aws s3api put-public-access-block --bucket "$BACKUP_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption --bucket "$BACKUP_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-bucket-policy --bucket "$BACKUP_BUCKET" --policy "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": ["arn:aws:s3:::${BACKUP_BUCKET}", "arn:aws:s3:::${BACKUP_BUCKET}/*"],
    "Condition": {"Bool": {"aws:SecureTransport": "false"}}
  }]
}
EOF
)"

echo "== 3/4: Livscykelregel (14 dagar)"
aws s3api put-bucket-lifecycle-configuration --bucket "$BACKUP_BUCKET" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "expire-backups-14-days",
      "Status": "Enabled",
      "Filter": {"Prefix": "backup/"},
      "Expiration": {"Days": 14},
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
    }]
  }'
ssm_put backup-bucket "$BACKUP_BUCKET"

echo "== 4/4: IAM-policyer på $WEB_ROLE_NAME"
aws iam get-role --role-name "$WEB_ROLE_NAME" >/dev/null

aws iam put-role-policy --role-name "$WEB_ROLE_NAME" \
  --policy-name novatrix-v45-s3-backup \
  --policy-document "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "WriteBackups",
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:AbortMultipartUpload"],
    "Resource": "arn:aws:s3:::${BACKUP_BUCKET}/backup/*"
  }]
}
EOF
)"

aws iam put-role-policy --role-name "$WEB_ROLE_NAME" \
  --policy-name novatrix-v45-ssm-read \
  --policy-document "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "ReadOwnConfig",
    "Effect": "Allow",
    "Action": "ssm:GetParameter",
    "Resource": "arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter${SSM_PREFIX}/*"
  }]
}
EOF
)"
echo "   + IAM-policyer uppdaterade"
echo "   Väntar 15 sekunder på att IAM-policyerna sprids..."
sleep 15
```

### `deploy.sh`
```bash
#!/bin/bash
set -e
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"
DIR="$(cd "$(dirname "$0")" && pwd)"
KEY="${KEY:-../V44/novatrix-key.pem}"

"$DIR/01-network.sh"
"$DIR/02-database.sh"
"$DIR/03-storage.sh"
"$DIR/04-s3-backup.sh"

echo ""
echo "============================================================"
echo " Infrastrukturen är klar. Startar automatisk server-setup..."
echo "============================================================"

q() { aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].$2" --output text; }
BASTION_IP=$(q novatrix-bastion PublicIpAddress)
WEB_PRIV_IP=$(q novatrix-web PrivateIpAddress)
WEB_PUB_DNS=$(q novatrix-web PublicDnsName)

if [ -z "$WEB_PUB_DNS" ] || [ "$WEB_PUB_DNS" = "None" ]; then
  WEB_PUB_DNS=$(q novatrix-web PublicIpAddress)
fi

echo ""
echo "Väntar 20 sekunder på att IAM-policyerna ska spridas i AWS..."
sleep 20

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
PROXY_CMD="ssh -i $KEY -W %h:%p ec2-user@$BASTION_IP"

echo "1/2: Kopierar server-skripten via bastionen..."
scp -i "$KEY" $SSH_OPTS -o ProxyCommand="$PROXY_CMD" -r "$DIR/server" ec2-user@$WEB_PRIV_IP:~/

echo "2/2: Loggar in och installerar WordPress (kan ta 2-3 minuter)..."
# timeout 600 ser till att hela SSH-anslutningen dör om något går fel
timeout 600 ssh -i "$KEY" $SSH_OPTS -o ProxyCommand="$PROXY_CMD" ec2-user@$WEB_PRIV_IP \
  "export SITE_HOST='$WEB_PUB_DNS' && cd server && chmod +x *.sh && sudo -E ./setup-wordpress.sh"

echo ""
echo "============================================================"
echo " ALLT KLART!"
echo " Webbplats: http://$WEB_PUB_DNS/"
echo " Admin:     http://$WEB_PUB_DNS/wp-admin"
echo ""
echo " Kör 'bash verify.sh' för att samla bevis."
echo "============================================================"
```

### `server/setup-wordpress.sh`
```bash
#!/bin/bash
# Körs på webbservern som root: sudo -E ./setup-wordpress.sh
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Kör med sudo"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WP_DIR=/var/www/html
WP_CONTENT="$WP_DIR/wp-content"

TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 120')
imds() { curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/$1" || true; }
export AWS_DEFAULT_REGION=$(imds placement/region)

if [ -z "${SITE_HOST:-}" ]; then
  SITE_HOST=$(imds public-hostname)
  [ -n "$SITE_HOST" ] || SITE_HOST=$(imds public-ipv4)
fi

get_param() {
  local name="/novatrix/$1"
  local value=""
  for i in {1..12}; do
    value=$(aws ssm get-parameter --name "$name" --with-decryption \
      --query Parameter.Value --output text 2>/dev/null || true)
    if [ -n "$value" ] && [ "$value" != "None" ]; then
      echo "$value"
      return 0
    fi
    echo "   Väntar på IAM-behörighet för $name (försök $i/12)..." >&2
    sleep 5
  done
  echo "FEL: Kunde inte läsa $name från SSM efter 60 sekunder." >&2
  return 1
}

echo "== 1/8: Läser SSM"
DB_ENDPOINT=$(get_param db-endpoint)
DB_NAME=$(get_param db-name)
DB_USER=$(get_param db-user)
DB_PASSWORD=$(get_param db-password)
WP_ADMIN_PASSWORD=$(get_param wp-admin-password)
EFS_ID=$(get_param efs-id)
echo "   DB: $DB_ENDPOINT | EFS: $EFS_ID | Site: $SITE_HOST"

echo "== 2/8: Installerar paket (inklusive php-zip)"
dnf install -y httpd php php-fpm php-mysqlnd php-gd php-xml php-mbstring \
  php-intl php-opcache php-cli php-zip mariadb105 amazon-efs-utils cronie

echo "== 3/8: Monterar EFS"
mkdir -p "$WP_CONTENT"
grep -q "$EFS_ID" /etc/fstab || \
  echo "${EFS_ID}:/ ${WP_CONTENT} efs _netdev,noresvport,tls 0 0" >> /etc/fstab

if ! mountpoint -q "$WP_CONTENT"; then
  for i in {1..3}; do
    echo "   Försöker montera EFS (försök $i/3)..."
    ( mount -t efs -o tls "$EFS_ID":/ "$WP_CONTENT" ) &
    MOUNT_PID=$!
    
    for j in {1..45}; do
      if ! kill -0 $MOUNT_PID 2>/dev/null; then break; fi
      sleep 1
    done
    
    if kill -0 $MOUNT_PID 2>/dev/null; then
      echo "   VARNING: Mount hängde sig. Dödar processen..."
      kill -9 $MOUNT_PID 2>/dev/null || true
      umount "$WP_CONTENT" 2>/dev/null || true
    elif mountpoint -q "$WP_CONTENT"; then
      echo "   Montering lyckades!"
      break
    fi
    
    echo "   Misslyckades, väntar 15 sekunder..."
    sleep 15
  done

  if ! mountpoint -q "$WP_CONTENT"; then
    echo "FEL: Kunde inte montera EFS efter 3 försök."
    exit 1
  fi
fi

chown -R apache:apache "$WP_CONTENT"
# Fix: Sätt rättigheter utan att göra filer exekverbara
find "$WP_CONTENT" -type d -exec chmod 755 {} +
find "$WP_CONTENT" -type f -exec chmod 644 {} +
df -hT "$WP_CONTENT" | tail -1

echo "== 4/8: Laddar ner AWS CA-certifikat för RDS"
mkdir -p /etc/ssl/rds
curl -sS -o /etc/ssl/rds/global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
chmod 644 /etc/ssl/rds/global-bundle.pem

echo "== 5/8: wp-cli"
if ! command -v wp >/dev/null; then
  curl -fsSL -o /usr/local/bin/wp \
    https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x /usr/local/bin/wp
fi
WP="wp --allow-root --path=$WP_DIR"

echo "== 6/8: Testar DB-anslutning (med SSL)"
MYSQL_PWD="$DB_PASSWORD" mysql --ssl -h "$DB_ENDPOINT" -u "$DB_USER" "$DB_NAME" \
  -e 'SELECT 1' >/dev/null 2>&1 || {
    echo "FEL: Kan inte nå RDS."
    exit 1
  }
echo "   DB OK (med SSL)"

echo "== 7/8: Laddar ner WordPress + konfiguration"
if [ ! -f "$WP_DIR/wp-includes/version.php" ]; then
  cd /tmp
  curl -fsSL -o latest.tar.gz https://wordpress.org/latest.tar.gz
  tar -xzf latest.tar.gz
  cp -r /tmp/wordpress/* "$WP_DIR/"
  rm -rf /tmp/wordpress /tmp/latest.tar.gz
fi

if [ ! -f "$WP_DIR/wp-config.php" ]; then
  cd "$WP_DIR"
  cp wp-config-sample.php wp-config.php
  sed -i "s/database_name_here/$DB_NAME/" wp-config.php
  sed -i "s/username_here/$DB_USER/" wp-config.php
  sed -i "s/password_here/$DB_PASSWORD/" wp-config.php
  sed -i "s/localhost/$DB_ENDPOINT/" wp-config.php
  # Fix: Generera unika säkerhetsnycklar direkt
  $WP config shuffle-salts
fi

$WP config set DISALLOW_FILE_EDIT true --raw --type=constant
$WP config set MYSQL_CLIENT_FLAGS MYSQLI_CLIENT_SSL --raw --type=constant
$WP config set MYSQL_SSL_CA "/etc/ssl/rds/global-bundle.pem" --type=constant

if ! $WP core is-installed 2>/dev/null; then
  $WP core install --url="http://$SITE_HOST" --title="Novatrix AB" \
    --admin_user="novatrix_admin" --admin_password="$WP_ADMIN_PASSWORD" \
    --admin_email="admin@novatrix.example" --skip-email
fi

echo "== 8/8: Apache, rättigheter, cron"
cat > /etc/httpd/conf.d/novatrix.conf <<'CONF'
ServerTokens Prod
ServerSignature Off
<Directory /var/www/html>
    Options -Indexes +FollowSymLinks
    AllowOverride All
</Directory>
CONF

chown -R apache:apache "$WP_DIR"
chown root:apache "$WP_DIR/wp-config.php"
chmod 640 "$WP_DIR/wp-config.php"

# Fix: Flytta bort v44-sidan så att WordPress (index.php) tar över
[ -f "$WP_DIR/index.html" ] && mv "$WP_DIR/index.html" "$WP_DIR/index.html.v44" || true

systemctl enable --now php-fpm httpd
systemctl restart php-fpm httpd

install -m 750 -o root -g root "$SCRIPT_DIR/backup.sh" /usr/local/bin/novatrix-backup.sh
echo '0 2 * * * root /usr/local/bin/novatrix-backup.sh >> /var/log/novatrix-backup.log 2>&1' \
  > /etc/cron.d/novatrix-backup
systemctl enable --now crond

echo ""
echo "KLART! Webbplats: http://$SITE_HOST/"
```

### `server/backup.sh`
```bash
#!/bin/bash
set -euo pipefail

TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
export AWS_DEFAULT_REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

get_param() { aws ssm get-parameter --name "/novatrix/$1" --with-decryption \
  --query Parameter.Value --output text; }

DB_ENDPOINT=$(get_param db-endpoint)
DB_NAME=$(get_param db-name)
DB_USER=$(get_param db-user)
DB_PASSWORD=$(get_param db-password)
BUCKET=$(get_param backup-bucket)

TS=$(date +%Y%m%d-%H%M%S)
FILE="/tmp/${DB_NAME}-${TS}.sql.gz"
trap 'rm -f "$FILE"' EXIT

echo "[$(date -Is)] Dumpar $DB_NAME från $DB_ENDPOINT"
MYSQL_PWD="$DB_PASSWORD" mysqldump --ssl \
  --host="$DB_ENDPOINT" --user="$DB_USER" \
  --single-transaction --quick --no-tablespaces \
  "$DB_NAME" | gzip -9 > "$FILE"

SIZE=$(du -h "$FILE" | cut -f1)
aws s3 cp "$FILE" "s3://${BUCKET}/backup/${DB_NAME}-${TS}.sql.gz" --only-show-errors
echo "[$(date -Is)] Klart: s3://${BUCKET}/backup/${DB_NAME}-${TS}.sql.gz (${SIZE})"
```

### `verify.sh`
```bash
#!/bin/bash
set -e
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"
load_ids

echo "========== RDS =========="
aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Class:DBInstanceClass,MultiAZ:MultiAZ,Public:PubliclyAccessible,Encrypted:StorageEncrypted,BackupDays:BackupRetentionPeriod,Endpoint:Endpoint.Address}' \
  --output table

echo ""
echo "========== EFS =========="
EFS_ID=$(aws efs describe-file-systems --creation-token "$EFS_NAME" \
  --query 'FileSystems[0].FileSystemId' --output text)
aws efs describe-file-systems --file-system-id "$EFS_ID" \
  --query 'FileSystems[0].{Id:FileSystemId,Encrypted:Encrypted,State:LifeCycleState}' --output table
aws efs describe-mount-targets --file-system-id "$EFS_ID" \
  --query 'MountTargets[].[AvailabilityZoneName,SubnetId,LifeCycleState]' --output table

echo ""
echo "========== S3 =========="
aws s3api get-bucket-lifecycle-configuration --bucket "$BACKUP_BUCKET" \
  --query 'Rules[0].{ID:ID,Status:Status,Prefix:Filter.Prefix,ExpiresAfterDays:Expiration.Days}' --output table
aws s3api get-public-access-block --bucket "$BACKUP_BUCKET" \
  --query 'PublicAccessBlockConfiguration' --output table
echo "Backuper:"
aws s3 ls "s3://$BACKUP_BUCKET/backup/" || echo "  (inga än)"

echo ""
echo "========== Säkerhet =========="
echo "--- db-sg:"
aws ec2 describe-security-groups --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions[].[FromPort,ToPort,UserIdGroupPairs[0].GroupId]' --output table
echo "--- efs-sg:"
aws ec2 describe-security-groups --filters "Name=group-name,Values=$EFS_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].IpPermissions[].[FromPort,ToPort,UserIdGroupPairs[0].GroupId]' --output table
echo "--- Inline-policyer:"
aws iam list-role-policies --role-name "$WEB_ROLE_NAME" --output table
echo "--- Managed policies:"
aws iam list-attached-role-policies --role-name "$WEB_ROLE_NAME" --output table
echo "--- NACL:"
PUB_NACL_ID=$(lookup_nacl "$VPC_ID" "$PUB_NACL_NAME")
aws ec2 describe-network-acls --network-acl-ids "$PUB_NACL_ID" \
  --query 'NetworkAcls[0].Entries[].[Egress,RuleNumber,RuleAction,PortRange.From,PortRange.To,CidrBlock]' --output table
echo "--- Privat NACL:"
PRIV_NACL_ID=$(lookup_nacl "$VPC_ID" "$PRIV_NACL_NAME")
aws ec2 describe-network-acls --network-acl-ids "$PRIV_NACL_ID" \
  --query 'NetworkAcls[0].Entries[].[Egress,RuleNumber,RuleAction,PortRange.From,PortRange.To,CidrBlock]' --output table
PUB=$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].PubliclyAccessible' --output text)
[ "$PUB" = "False" ] && echo "OK: RDS är privat." || echo "FEL: RDS är publik!"
```

### `teardown-v45.sh`
```bash
#!/bin/bash
set -e
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-north-1}"

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"
load_ids

read -r -p "Detta raderar RDS, EFS och $BACKUP_BUCKET permanent. Skriv 'radera': " ANS
[ "$ANS" = "radera" ] || { echo "Avbryter."; exit 1; }

echo "== RDS"
if aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" >/dev/null 2>&1; then
  aws rds delete-db-instance --db-instance-identifier "$DB_INSTANCE" \
    --skip-final-snapshot --delete-automated-backups >/dev/null
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE"
fi
aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" 2>/dev/null || true

echo "== EFS"
EFS_ID=$(aws efs describe-file-systems --creation-token "$EFS_NAME" \
  --query 'FileSystems[0].FileSystemId' --output text 2>/dev/null || true)
if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
  for MT in $(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
    --query 'MountTargets[].MountTargetId' --output text); do
    aws efs delete-mount-target --mount-target-id "$MT"
  done
  until [ -z "$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
    --query 'MountTargets[].MountTargetId' --output text)" ]; do sleep 5; done
  aws efs delete-file-system --file-system-id "$EFS_ID"
fi
EFS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$EFS_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [ -n "$EFS_SG_ID" ] && [ "$EFS_SG_ID" != "None" ]; then
  for i in 1 2 3 4 5 6; do
    aws ec2 delete-security-group --group-id "$EFS_SG_ID" 2>/dev/null && break || sleep 10
  done
fi

echo "== S3"
if aws s3api head-bucket --bucket "$BACKUP_BUCKET" 2>/dev/null; then
  aws s3 rm "s3://$BACKUP_BUCKET" --recursive --only-show-errors
  aws s3api delete-bucket --bucket "$BACKUP_BUCKET"
fi

echo "== IAM + SSM"
aws iam delete-role-policy --role-name "$WEB_ROLE_NAME" --policy-name novatrix-v45-s3-backup 2>/dev/null || true
aws iam delete-role-policy --role-name "$WEB_ROLE_NAME" --policy-name novatrix-v45-ssm-read 2>/dev/null || true
for p in db-endpoint db-name db-user db-password wp-admin-password efs-id backup-bucket; do
  aws ssm delete-parameter --name "$SSM_PREFIX/$p" 2>/dev/null || true
done

echo "== NACL + db-sg"
PRIV_NACL_ID=$(lookup_nacl "$VPC_ID" "$PRIV_NACL_NAME")
aws ec2 delete-network-acl-entry --network-acl-id "$PRIV_NACL_ID" --rule-number 110 --ingress 2>/dev/null || true

NACL_ID=$(lookup_nacl "$VPC_ID" "$PUB_NACL_NAME")
aws ec2 delete-network-acl-entry --network-acl-id "$NACL_ID" --rule-number 140 --egress  2>/dev/null || true
aws ec2 delete-network-acl-entry --network-acl-id "$NACL_ID" --rule-number 150 --egress  2>/dev/null || true
aws ec2 delete-network-acl-entry --network-acl-id "$NACL_ID" --rule-number 160 --ingress 2>/dev/null || true
aws ec2 revoke-security-group-ingress --group-id "$DB_SG_ID" --protocol tcp --port 3306 \
  --source-group "$WEB_SG_ID" >/dev/null 2>&1 || true

echo "Klart."
```

### `.gitignore`
```text
*.pem
.env
```