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
  echo "❌ Run as root"
  exit 1
fi

####################################
# OS DETECTION
####################################
log "Detecting OS"
OS_ID=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
OS_VER=$(lsb_release -rs | cut -d. -f1)
CODENAME=$(lsb_release -cs)
log "Detected $OS_ID $OS_VER ($CODENAME)"

####################################
# BASE DEPENDENCIES
####################################
log "Installing base dependencies"
export DEBIAN_FRONTEND=noninteractive
run apt update -qq

run apt install -y \
  curl ca-certificates gnupg gnupg2 sudo lsb-release apt-transport-https

####################################
# PHP REPO
####################################
if [[ "$OS_ID" == "ubuntu" ]]; then
  log "Adding PHP repo (Ubuntu)"
  run add-apt-repository -y ppa:ondrej/php
fi

if [[ "$OS_ID" == "debian" ]]; then
  log "Adding PHP repo (Debian – Sury, Debian 13 safe)"

  run curl -fsSL https://packages.sury.org/php/apt.gpg -o /tmp/sury.gpg
  gpg --dearmor /tmp/sury.gpg > /etc/apt/trusted.gpg.d/sury-php.gpg
  rm -f /tmp/sury.gpg

  echo "deb https://packages.sury.org/php/ $CODENAME main" \
    > /etc/apt/sources.list.d/sury-php.list
fi

####################################
# REDIS REPO (FIXED FOR DEBIAN 13)
####################################
log "Adding Redis repo (Debian 13 safe)"

run curl -fsSL https://packages.redis.io/gpg -o /tmp/redis.gpg
gpg --dearmor /tmp/redis.gpg > /usr/share/keyrings/redis-archive-keyring.gpg
rm -f /tmp/redis.gpg

echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] \
https://packages.redis.io/deb $CODENAME main" \
> /etc/apt/sources.list.d/redis.list

####################################
# MARIADB REPO (DEBIAN 11 & 12 ONLY)
####################################
if [[ "$OS_ID" == "debian" && ( "$OS_VER" == "11" || "$OS_VER" == "12" ) ]]; then
  log "Adding MariaDB repo"
  run curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash
fi

####################################
# INSTALL PACKAGES
####################################
log "Installing required packages (this may take a few minutes)"
run apt update -qq
run apt install -y \
  php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} \
  mariadb-server nginx tar unzip git redis-server

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
log "Configuring application environment"

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
# CRON
####################################
log "Setting up cron"
(crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -

####################################
# QUEUE WORKER
####################################
log "Setting up queue worker"

cat > /etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

run systemctl daemon-reload
run systemctl enable --now redis-server pteroq

####################################
# SSL
####################################
log "Generating self-signed SSL"
mkdir -p /etc/certs
run openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
  -keyout /etc/certs/privkey.pem \
  -out /etc/certs/fullchain.pem \
  -subj "/CN=$USER_DOMAIN"

####################################
# NGINX
####################################
log "Configuring NGINX"
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
  listen 80;
  server_name $USER_DOMAIN;
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl http2;
  server_name $USER_DOMAIN;

  root /var/www/pterodactyl/public;
  index index.php;

  ssl_certificate /etc/certs/fullchain.pem;
  ssl_certificate_key /etc/certs/privkey.pem;

  client_max_body_size 100m;

  location / {
    try_files \$uri \$uri/ /index.php?\$query_string;
  }

  location ~ \.php$ {
    fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
  }
}
EOF

ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
run systemctl restart nginx

####################################
# DONE
####################################
echo
echo "✅ INSTALLATION COMPLETE"
echo "🌐 Panel URL: https://$USER_DOMAIN"
