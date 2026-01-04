#!/bin/bash

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Helper functions for status reporting
print_status() { echo -e "\e[34m[INFO]\e[0m $1"; }
check_success() { if [ $? -eq 0 ]; then echo -e "\e[32m[SUCCESS]\e[0m $1"; else echo -e "\e[31m[ERROR]\e[0m $2"; exit 1; fi }

# 1. Install Docker
print_status "Installing Docker..."
# Redirecting all output to /dev/null to keep it clean
curl -sSL https://get.docker.com/ | CHANNEL=stable bash >
systemctl enable --now docker > /dev/null 2>&1
check_success "Docker installed and started" "Docker installation failed"

# 2. Update GRUB (Swap Support)
GRUB_FILE="/etc/default/grub"
if [ -f "$GRUB_FILE" ] && ! grep -q "swapaccount=1" "$GRUB_FILE"; then
    print_status "Enabling Docker swap accounting in GRUB..."
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&swapaccount=1 /' $GRUB_FILE
    update-grub > /dev/null 2>&1
    print_status "GRUB updated. NOTE: A reboot is required for swap limits to take effect."
fi

# 3. Download Wings Binary
print_status "Downloading Wings binary..."
mkdir -p /etc/pterodactyl
ARCH=$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")
curl -L -s -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$ARCH"
chmod u+x /usr/local/bin/wings
check_success "Wings binary downloaded" "Failed to download Wings"

# 4. Create Systemd Service
print_status "Creating Wings systemd service..."
cat <<EOF > /etc/systemd/system/wings.service
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload > /dev/null 2>&1
systemctl enable wings > /dev/null 2>&1
check_success "Systemd service configured" "Failed to reload daemon"

# 5. Generate SSL Certificates
print_status "Generating self-signed SSL certificates..."
mkdir -p /etc/certs/wings
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
    -keyout /etc/certs/wings/privkey.pem \
    -out /etc/certs/wings/fullchain.pem > /dev/null 2>&1
check_success "SSL certificates generated" "SSL generation failed"

# 6. Get User Configuration
# We use < /dev/tty so the script can read your typing while being piped from curl
echo "-------------------------------------------------------"
echo "Please enter the configuration details from your Panel:"
read -p "Node UUID: " UUID < /dev/tty
read -p "Token ID: " TOKEN_ID < /dev/tty
read -p "Token: " TOKEN < /dev/tty
read -p "Remote URL (e.g., https://panel.example.com): " REMOTE < /dev/tty
echo "-------------------------------------------------------"

# 7. Write Config File
print_status "Writing wings configuration..."
cat <<CFG > /etc/pterodactyl/config.yml
debug: false
uuid: ${UUID}
token_id: ${TOKEN_ID}
token: ${TOKEN}
api:
  host: 0.0.0.0
  port: 8080
  ssl:
    enabled: true
    cert: /etc/certs/wings/fullchain.pem
    key: /etc/certs/wings/privkey.pem
  upload_limit: 100
system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: 2022
allowed_mounts: []
remote: '${REMOTE}'
CFG

# 8. Start Wings
print_status "Starting Wings..."
systemctl start wings > /dev/null 2>&1
check_success "Wings is now running!" "Wings failed to start."
