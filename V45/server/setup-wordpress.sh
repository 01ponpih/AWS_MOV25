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