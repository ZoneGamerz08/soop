#!/bin/bash

# Abort on error
set -e

# ---------------------------------------------------------
# ROOT CHECK
# ---------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root"
  exit 1
fi

# ---------------------------------------------------------
# 1. GET CREDENTIALS FROM USER (PIPE SAFE)
# ---------------------------------------------------------
get_credentials() {
    echo "======================================"
    echo " Pterodactyl Panel Installation Setup "
    echo "======================================"
    echo

    read -rp "Enter Panel Domain (e.g. panel.example.com): " USER_DOMAIN </dev/tty
    read -rp "Enter Admin Email: " ADMIN_EMAIL </dev/tty
    read -rp "Enter Admin Username: " ADMIN_USER </dev/tty

    while true; do
        read -rsp "Enter Admin Password: " ADMIN_PASS </dev/tty
        echo
        read -rsp "Confirm Admin Password: " ADMIN_PASS_CONFIRM </dev/tty
        echo
        if [[ -n "$ADMIN_PASS" && "$ADMIN_PASS" == "$ADMIN_PASS_CONFIRM" ]]; then
            break
        else
            echo "❌ Passwords do not match or are empty. Try again."
        fi
    done

    while true; do
        read -rsp "Enter Database Password: " DB_PASSWORD </dev/tty
        echo
        read -rsp "Confirm Database Password: " DB_PASSWORD_CONFIRM </dev/tty
        echo
        if [[ -n "$DB_PASSWORD" && "$DB_PASSWORD" == "$DB_PASSWORD_CONFIRM" ]]; then
            break
        else
            echo "❌ Database passwords do not match or are empty. Try again."
        fi
    done

    export USER_DOMAIN ADMIN_EMAIL ADMIN_USER ADMIN_PASS DB_PASSWORD

    echo
    echo "✅ Credentials saved. Starting installation..."
    echo
}

get_credentials

# ---------------------------------------------------------
# 2. OS DETECTION & REPOS (MAX SPEED)
# ---------------------------------------------------------
source /etc/os-release
OS=$ID
VERSION=$VERSION_ID
CODENAME=$(lsb_release -sc)

echo "[INFO] Detected $OS $VERSION ($CODENAME)"

export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o APT::Install-Recommends=0 -o APT::Install-Suggests=0"

# Base tooling (no update yet)
apt-get install -y $APT_OPTS \
  ca-certificates curl gnupg lsb-release apt-transport-https sudo

# PHP (Sury)
curl -fsSL https://packages.sury.org/php/apt.gpg \
  | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury.gpg

echo "deb https://packages.sury.org/php/ $CODENAME main" \
  > /etc/apt/sources.list.d/sury-php.list

# Redis
curl -fsSL https://packages.redis.io/gpg \
  | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] \
https://packages.redis.io/deb $CODENAME main" \
  > /etc/apt/sources.list.d/redis.list

# MariaDB (manual, no setup script)
curl -fsSL https://mariadb.org/mariadb_release_signing_key.asc \
  | gpg --dearmor -o /etc/apt/trusted.gpg.d/mariadb.gpg

echo "deb https://mirror.mariadb.org/repo/11.4/debian $CODENAME main" \
  > /etc/apt/sources.list.d/mariadb.list

# Single metadata refresh
apt-get update -y

# ---------------------------------------------------------
# 3. INSTALL DEPENDENCIES
# ---------------------------------------------------------
apt-get install -y $APT_OPTS \
  php8.3 php8.3-{cli,common,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} \
  mariadb-server nginx redis-server git tar unzip

curl -sS https://getcomposer.org/installer \
  | php -- --install-dir=/usr/local/bin --filename=composer

# ---------------------------------------------------------
# 4. DOWNLOAD PANEL
# ---------------------------------------------------------
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

curl -Lo panel.tar.gz \
https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz

tar -xzf panel.tar.gz
chmod -R 755 storage bootstrap/cache

# ---------------------------------------------------------
# 5. DATABASE SETUP
# ---------------------------------------------------------
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS panel;
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

# ---------------------------------------------------------
# 6. PANEL CONFIGURATION
# ---------------------------------------------------------
cp .env.example .env

COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
php artisan key:generate --force

php artisan p:environment:setup \
  --author="$ADMIN_EMAIL" \
  --url="https://$USER_DOMAIN" \
  --timezone=UTC \
  --cache=redis \
  --session=redis \
  --queue=redis \
  --redis-host=127.0.0.1 \
  --redis-port=6379 \
  --redis-pass="" \
  --settings-ui=true \
  --telemetry=false

php artisan p:environment:database \
  --host=127.0.0.1 \
  --port=3306 \
  --database=panel \
  --username=pterodactyl \
  --password="$DB_PASSWORD"

php artisan migrate --seed --force

php artisan p:user:make \
  --email="$ADMIN_EMAIL" \
  --username="$ADMIN_USER" \
  --name-first=Admin \
  --name-last=User \
  --password="$ADMIN_PASS" \
  --admin=1

chown -R www-data:www-data /var/www/pterodactyl

# ---------------------------------------------------------
# 7. CRON & QUEUE
# ---------------------------------------------------------
echo "* * * * * www-data php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1" \
  > /etc/cron.d/pterodactyl

cat > /etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work \
--queue=high,standard,low --sleep=3 --tries=3
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now redis-server pteroq.service

# ---------------------------------------------------------
# 8. NGINX + SSL
# ---------------------------------------------------------
mkdir -p /etc/certs

openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/CN=$USER_DOMAIN" \
  -keyout /etc/certs/privkey.pem \
  -out /etc/certs/fullchain.pem

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

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

ln -sf /etc/nginx/sites-available/pterodactyl.conf \
/etc/nginx/sites-enabled/pterodactyl.conf

systemctl restart nginx php8.3-fpm

# ---------------------------------------------------------
# DONE
# ---------------------------------------------------------
echo
echo "✅ INSTALLATION COMPLETE"
echo "🌐 https://$USER_DOMAIN"
echo "👤 Admin: $ADMIN_USER"
echo
