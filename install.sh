#!/bin/bash
set -e

# Collect installation credentials from the user
echo "Pterodactyl Panel Installation Setup"
echo "======================================"
read -rp "Enter Panel Domain (e.g. panel.example.com): " USER_DOMAIN </dev/tty
read -rp "Enter Admin Email: " ADMIN_EMAIL </dev/tty
read -rp "Enter Admin Username: " ADMIN_USER </dev/tty
read -rsp "Enter Admin Password: " ADMIN_PASS </dev/tty
echo

# Generate a secure 32-character database password
DB_PASSWORD="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"

# Ensure the script is running with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root"
  exit 1
fi

# Detect operating system details
source /etc/os-release
OS=$ID
VERSION_ID=$VERSION_ID

# Configure software repositories for Ubuntu systems
if [[ "$OS" == "ubuntu" ]]; then
    apt update -y > /dev/null 2>&1
    apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg > /dev/null 2>&1
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php > /dev/null 2>&1
    curl -fsSL https://packages.redis.io/gpg | gpg --yes --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg > /dev/null 2>&1
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list > /dev/null 2>&1

# Configure software repositories for Debian systems
elif [[ "$OS" == "debian" ]]; then
    apt update -y > /dev/null 2>&1
    apt install -y curl ca-certificates gnupg2 lsb-release > /dev/null 2>&1
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/sury-php.list > /dev/null 2>&1
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --yes --dearmor -o /etc/apt/trusted.gpg.d/sury-keyring.gpg > /dev/null 2>&1
    if [[ "$VERSION_ID" == "11" || "$VERSION_ID" == "12" ]]; then
        curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash > /dev/null 2>&1
        curl -fsSL https://packages.redis.io/gpg | gpg --yes --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg > /dev/null 2>&1
        echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list > /dev/null 2>&1
    fi
else
    echo "❌ Unsupported Operating System: $OS"
    exit 1
fi

# Install core PHP 8.3 and database dependencies
apt update -y
DEBIAN_FRONTEND=noninteractive apt install -y php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server

# Install the PHP Composer binary globally
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Download and unpack the Pterodactyl Panel source code
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# Setup the MariaDB database and administrative user
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS panel;
CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

# Initialize application environment and generate encryption keys
cp .env.example .env
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
php artisan key:generate --force

# Configure application settings via the CLI
php artisan p:environment:setup --author="$ADMIN_EMAIL" --url="https://$USER_DOMAIN" --timezone="UTC" --cache="redis" --session="redis" --queue="redis" --redis-host="127.0.0.1" --redis-port="6379" --redis-pass="" --settings-ui=true --telemetry=false

# Link the panel to the MariaDB database
php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="$DB_PASSWORD"

# Migrate the database schema and seed default values
php artisan migrate --seed --force

# Create the primary administrator account for the web UI
php artisan p:user:make --email="$ADMIN_EMAIL" --username="$ADMIN_USER" --name-first="Admin" --name-last="User" --password="$ADMIN_PASS" --admin=1

# Ensure proper file permissions for the web server
chown -R www-data:www-data /var/www/pterodactyl

# Configure the system crontab for scheduled tasks
echo "* * * * * www-data php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1" > /etc/cron.d/pterodactyl

# Create the systemd service for background queue processing
cat > /etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service
[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF

# Activate and start the Redis and Queue services
systemctl enable --now redis-server pteroq.service

# Generate local SSL certificates for secure access
mkdir -p /etc/certs
if [ ! -f /etc/certs/fullchain.pem ]; then
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" -keyout /etc/certs/privkey.pem -out /etc/certs/fullchain.pem
fi

# Configure Nginx with the panel site definition
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${USER_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${USER_DOMAIN};
    root /var/www/pterodactyl/public;
    ssl_certificate /etc/certs/fullchain.pem;
    ssl_certificate_key /etc/certs/privkey.pem;
    index index.php;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

# Apply the Nginx configuration and restart the service
ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
systemctl restart nginx

# Output the final status and access credentials
echo "✅ INSTALLATION COMPLETE"
echo "🌐 Panel URL: https://${USER_DOMAIN}"
echo "🔐 DB Password: ${DB_PASSWORD}"
