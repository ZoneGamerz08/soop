#!/bin/bash

# Pterodactyl Panel Optimized Installer
# PHP 8.3 | MariaDB | Redis | Nginx
set -e

clear
echo "-------------------------------------------------------"
echo " Pterodactyl Panel Setup - Configuration"
echo "-------------------------------------------------------"

# 1. MANUAL INPUT SECTION
echo "Please enter the following details:"

printf "Panel Domain (e.g., panel.example.com): "
read USER_DOMAIN

printf "Admin Email: "
read ADMIN_EMAIL

printf "Admin Username: "
read ADMIN_USER

printf "Admin Password: "
read -s ADMIN_PASS
echo "" # Moves to a new line after hidden password input

# Validation: Check if any of these are empty
if [[ -z "$USER_DOMAIN" || -z "$ADMIN_EMAIL" || -z "$ADMIN_USER" || -z "$ADMIN_PASS" ]]; then
    echo "Error: You left one or more fields blank. Please run the script again."
    exit 1
fi

DB_PASSWORD=$(openssl rand -base64 12)
export DEBIAN_FRONTEND=noninteractive

# 2. SYSTEM REPO SETUP
echo "Adding Repositories..."
apt-get update -y
apt-get install -yq curl ca-certificates gnupg2 lsb-release

# PHP Repo Setup
curl -fsSL https://packages.sury.org/php/apt.gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-keyring.gpg --yes
echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/sury-php.list

# 3. INSTALLATION
apt-get update -y
apt-get install -yq --no-install-recommends \
    php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} \
    mariadb-server mariadb-client nginx redis-server tar unzip git cron

# 4. PANEL SETUP
echo "Downloading and preparing Panel..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
mkdir -p /var/www/pterodactyl && cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# Database Logic
echo "Configuring MariaDB..."
mysql -u root -e "CREATE DATABASE IF NOT EXISTS panel; CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD'; GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1'; FLUSH PRIVILEGES;"

# Configuration
cp .env.example .env
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
php artisan key:generate --force

# Environment Setup
echo "Applying environment settings..."
php artisan p:environment:setup --author="$ADMIN_EMAIL" --url="https://$USER_DOMAIN" --timezone="UTC" --cache="redis" --session="redis" --queue="redis" --redis-host="127.0.0.1" --redis-port="6379" --redis-pass="" --settings-ui=true --telemetry=false
php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="$DB_PASSWORD"
php artisan migrate --seed --force

# Admin Creation
echo "Creating Admin Account..."
php artisan p:user:make --email="$ADMIN_EMAIL" --username="$ADMIN_USER" --name-first="Admin" --name-last="User" --password="$ADMIN_PASS" --admin=1
chown -R www-data:www-data /var/www/pterodactyl/*

echo "-------------------------------------------------------"
echo " Installation Success!"
echo " URL: https://$USER_DOMAIN"
echo " Database Password: $DB_PASSWORD"
echo "-------------------------------------------------------"
