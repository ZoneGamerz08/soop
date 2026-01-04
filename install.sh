#!/bin/bash

# Abort on any error
set -e

# ---------------------------------------------------------
# 1. MANUAL CREDENTIALS (EDIT THESE)
# ---------------------------------------------------------
USER_DOMAIN="panel.reyet.tech"
ADMIN_EMAIL="admin@yourdomaim.com"
ADMIN_USER="reyet"
ADMIN_PASS="Reyet696969"
DB_PASSWORD="YourSecureDatabasePassword"
# ---------------------------------------------------------

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

echo "[*] Starting optimized installation..."

# -----------------------------
# 2. OPTIMIZED OS DETECTION & REPOS
# -----------------------------
source /etc/os-release
OS=$ID
VERSION=$VERSION_ID

# Install initial requirements quietly
apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl ca-certificates gnupg2 sudo lsb-release apt-transport-https

# 1. Prepare PHP (Sury) Repo
curl -fsSL https://packages.sury.org/php/apt.gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-keyring.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/sury-keyring.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/sury-php.list

# 2. Prepare Redis Repo
curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list

# 3. Prepare MariaDB Repo (Manual injection bypasses slow setup script)
# Using MariaDB 10.11 LTS for maximum compatibility
if [[ "$OS" == "debian" ]]; then
    echo "deb [arch=amd64,arm64] https://archive.mariadb.org/mariadb-10.11/repo/debian $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/mariadb.list
elif [[ "$OS" == "ubuntu" ]]; then
    echo "deb [arch=amd64,arm64] https://archive.mariadb.org/mariadb-10.11/repo/ubuntu $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/mariadb.list
fi
sudo apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0xF1656F24C74CD1D8

# 4. SINGLE SYNC (The biggest time saver)
echo "[*] Synchronizing all repositories once..."
apt-get update -q

# -----------------------------
# 3. INSTALL DEPENDENCIES (Optimized)
# -----------------------------
echo "[*] Installing packages with no-recommends for speed..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
    php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} \
    mariadb-server nginx tar unzip git redis-server

curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer

# -----------------------------
# 4. DOWNLOAD & INSTALL PANEL
# -----------------------------
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# -----------------------------
# 5. DATABASE CONFIGURATION
# -----------------------------
sudo mysql -u root -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';"
sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS panel;"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"
sudo mysql -u root -e "FLUSH PRIVILEGES;"

# -----------------------------
# 6. PANEL CONFIGURATION
# -----------------------------
cp .env.example .env
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
php artisan key:generate --force

php artisan p:environment:setup \
    --author="$ADMIN_EMAIL" \
    --url="https://$USER_DOMAIN" \
    --timezone="UTC" \
    --cache="redis" \
    --session="redis" \
    --queue="redis" \
    --redis-host="127.0.0.1" \
    --redis-port="6379" \
    --redis-pass="" \
    --settings-ui=true \
    --telemetry=false

php artisan p:environment:database \
    --host="127.0.0.1" \
    --port="3306" \
    --database="panel" \
    --username="pterodactyl" \
    --password="$DB_PASSWORD"

php artisan migrate --seed --force

php artisan p:user:make \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USER" \
    --name-first="Admin" \
    --name-last="User" \
    --password="$ADMIN_PASS" \
    --admin=1

chown -R www-data:www-data /var/www/pterodactyl/*

# -----------------------------
# 7. CRON & QUEUE WORKER
# -----------------------------
echo "* * * * * www-data php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1" | sudo tee /etc/cron.d/pterodactyl

cat <<EOF > /etc/systemd/system/pteroq.service
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now redis-server
sudo systemctl enable --now pteroq.service

# -----------------------------
# 8. SSL & NGINX
# -----------------------------
mkdir -p /etc/certs
if [ ! -f /etc/certs/fullchain.pem ]; then
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
        -keyout /etc/certs/privkey.pem \
        -out /etc/certs/fullchain.pem
fi

rm -f /etc/nginx/sites-enabled/default
cat <<EOF > /etc/nginx/sites-available/pterodactyl.conf
server {
    listen 80;
    server_name $USER_DOMAIN;
    return 301 https://\$server_name\$request_uri;
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
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
sudo systemctl restart nginx

echo "Installation Complete! Go to: https://$USER_DOMAIN"
