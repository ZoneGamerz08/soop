#!/usr/bin/env bash
set -e

####################################
# CONFIG – EDIT THESE
####################################
ADMIN_EMAIL="admin@example.com"
ADMIN_USER="admin"
ADMIN_PASS="StrongAdminPassword"
DB_PASSWORD="StrongDBPassword"
USER_DOMAIN="panel.example.com"
TIMEZONE="UTC"

####################################
# LOGGING
####################################
log() {
  echo -e "\n\033[1;32m[INFO]\033[0m $1"
}

run() {
  "$@" >/dev/null 2>&1
}

####################################
# ROOT CHECK
####################################
if [ "$EUID" -ne 0 ]; then
  echo "❌ Run this script as root"
  exit 1
fi

####################################
# OS DETECTION
####################################
log "Detecting OS"
OS_ID=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
OS_VER=$(lsb_release -rs | cut -d. -f1)
CODENAME=$(lsb_release -cs)

APT_CODENAME="$CODENAME"
if [[ "$OS_ID" == "debian" && "$OS_VER" == "13" ]]; then
  APT_CODENAME="bookworm"
fi

log "Detected $OS_ID $OS_VER ($CODENAME → repos use $APT_CODENAME)"

####################################
# BASE DEPENDENCIES (SILENT)
####################################
log "Installing base dependencies"
export DEBIAN_FRONTEND=noninteractive
run apt update -qq
run apt install -y curl ca-certificates gnupg gnupg2 sudo lsb-release apt-transport-https software-properties-common

####################################
# PHP REPO
####################################
if [[ "$OS_ID" == "ubuntu" ]]; then
  log "Adding PHP repo (Ubuntu)"
  run add-apt-repository -y ppa:ondrej/php
fi

if [[ "$OS_ID" == "debian" ]]; then
  log "Adding PHP repo (Sury)"
  run curl -fsSL https://packages.sury.org/php/apt.gpg -o /tmp/sury.gpg
  gpg --dearmor /tmp/sury.gpg > /etc/apt/trusted.gpg.d/sury-php.gpg
  rm -f /tmp/sury.gpg

  echo "deb https://packages.sury.org/php/ $APT_CODENAME main" \
    > /etc/apt/sources.list.d/sury-php.list
fi

####################################
# REDIS REPO
####################################
log "Adding Redis repo"
run curl -fsSL https://packages.redis.io/gpg -o /tmp/redis.gpg
gpg --dearmor /tmp/redis.gpg > /usr/share/keyrings/redis-archive-keyring.gpg
rm -f /tmp/redis.gpg

echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] \
https://packages.redis.io/deb $APT_CODENAME main" \
> /etc/apt/sources.list.d/redis.list

####################################
# MARIADB REPO (DEBIAN 11 & 12 ONLY)
####################################
if [[ "$OS_ID" == "debian" && ( "$OS_VER" == "11" || "$OS_VER" == "12" ) ]]; then
  log "Adding MariaDB repo"
  run curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash
fi

####################################
# INSTALL PACKAGES (LOGS ENABLED HERE)
####################################
log "Installing required packages (LOGS ENABLED BELOW)"

apt update

apt install -y \
  php8.3 php8.3-common php8.3-cli php8.3-gd php8.3-mysql \
  php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-fpm \
  php8.3-curl php8.3-zip \
  mariadb-server nginx tar unzip git redis-server

####################################
# VERIFY PHP (IMPORTANT)
####################################
log "Verifying PHP installation"
php -v

####################################
# COMPOSER
####################################
log "Installing Composer"
run curl -sS https://getcomposer.org/installer | \
  php -- --install-dir=/usr/local/bin --filename=composer

####################################
# PTERODACTYL PANEL
####################################
log "Installing Pterodactyl Panel"
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

run curl -Lo panel.tar.gz \
https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
run tar -xzf panel.tar.gz

chmod -R 755 storage bootstrap/cache
cp .env.example .env

COMPOSER_ALLOW_SUPERUSER=1 run composer install --no-dev --optimize-autoloader
php artisan key:generate --force >/dev/null

####################################
# DATABASE
####################################
log "Configuring database"
mysql <<EOF
CREATE DATABASE IF NOT EXISTS panel;
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

####################################
# ENVIRONMENT (NON-INTERACTIVE)
####################################
log "Configuring environment"

php artisan p:environment:setup \
  --author="$ADMIN_EMAIL" \
  --url="https://$USER_DOMAIN" \
  --timezone="$TIMEZONE" \
  --cache=redis \
  --session=redis \
  --queue=redis \
  --redis-host=127.0.0.1 \
  --redis-port=6379 \
  --redis-pass="" \
  --settings-ui=true \
  --telemetry=false >/dev/null

php artisan p:environment:database \
  --host=127.0.0.1 \
  --port=3306 \
  --database=panel \
  --username=pterodactyl \
  --password="$DB_PASSWORD" >/dev/null

php artisan migrate --seed --force >/dev/null

php artisan p:user:make \
  --email="$ADMIN_EMAIL" \
  --username="$ADMIN_USER" \
  --name-first=Admin \
  --name-last=User \
  --password="$ADMIN_PASS" \
  --admin=1 >/dev/null

chown -R www-data:www-data /var/www/pterodactyl

####################################
# DONE
####################################
echo
echo "✅ INSTALLATION COMPLETE"
echo "🌐 Panel URL: https://$USER_DOMAIN"
