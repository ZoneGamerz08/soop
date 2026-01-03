#!/bin/bash

# Pterodactyl Panel Optimized Installer
# PHP 8.3 | MariaDB | Redis | Nginx
set -e

clear
echo "-------------------------------------------------------"
echo " Pterodactyl Panel Setup - Configuration"
echo "-------------------------------------------------------"

# Function to prompt for input
get_input() {
    local prompt=$1
    local var_name=$2
    local default_val=$3
    read -p "$prompt [Default: $default_val]: " input
    eval $var_name="${input:-$default_val}"
}

# 1. COLLECT DATA
read -p "Enter Panel Domain (e.g. panel.example.com): " USER_DOMAIN
if [[ -z "$USER_DOMAIN" ]]; then echo "Domain is required!"; exit 1; fi

get_input "Enter Admin Email" "ADMIN_EMAIL" "admin@example.com"
get_input "Enter Admin Username" "ADMIN_USER" "admin"

# Password prompt (hidden typing for security)
echo -n "Enter Admin Password: "
read -s ADMIN_PASS
echo ""

if [[ -z "$ADMIN_PASS" ]]; then echo "Password is required!"; exit 1; fi

DB_PASSWORD=$(openssl rand -base64 12)
export DEBIAN_FRONTEND=noninteractive

# 2. SYSTEM REPO SETUP
echo "Adding Repositories..."
apt-get update -y
apt-get install -yq curl ca-certificates gnupg2 lsb-release

until curl -fsSL https://packages.sury.org/php/apt.gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-keyring.gpg --yes; do
    echo "Retrying PHP repo download..."
    sleep 2
done
echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/sury-php.list

# 3. INSTALLATION
apt-get update -y
apt-get install -yq --no-install-recommends \
    php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} \
    mariadb-server mariadb-client nginx redis-server tar unzip git cron

# 4. PANEL SETUP
echo "Downloading Panel..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
mkdir -p /var/www/pterodactyl && cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# Database Logic
mysql -u root -e "CREATE DATABASE IF NOT EXISTS panel; CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD'; GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1'; FLUSH PRIVILEGES;"

# Configuration
cp .env.example .env
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
php artisan key:generate --force

# Environment Setup
php artisan p:environment:setup --author="$ADMIN_EMAIL" --url="https://$USER_DOMAIN" --timezone="UTC" --cache="redis" --session="redis" --queue="redis" --redis-host="127.0.0.1" --redis-port="6379" --redis-pass="" --settings-ui=true --telemetry=false
php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="$DB_PASSWORD"
php artisan migrate --seed --force

# Admin Creation
php artisan p:user:make --email="$ADMIN_EMAIL" --username="$ADMIN_USER" --name-first="Admin" --name-last="User" --password="$ADMIN_PASS" --admin=1
chown -R www-data:www-data /var/www/pterodactyl/*

echo "-------------------------------------------------------"
echo " Installation Success!"
echo " URL: https://$USER_DOMAIN"
echo " Admin User: $ADMIN_USER"
echo "-------------------------------------------------------"
