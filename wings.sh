#!/bin/bash
set -e

print_status() {
    echo -e "\n[INFO] $1"
}

check_success() {
    if [ $? -eq 0 ]; then
        echo "[OK] $1"
    else
        echo "[ERROR] $2"
        exit 1
    fi
}

# ------------------------
# 1. Install Docker
# ------------------------
print_status "Installing Docker"
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
check_success "Docker installed" "Docker installation failed"

sudo systemctl enable --now docker
check_success "Docker service enabled" "Failed to enable Docker"

# ------------------------
# 2. Update GRUB (Swap Support)
# ------------------------
GRUB_FILE="/etc/default/grub"
if [ -f "$GRUB_FILE" ] && ! grep -q "swapaccount=1" "$GRUB_FILE"; then
    print_status "Enabling Docker swap accounting"
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&swapaccount=1 /' $GRUB_FILE
    sudo update-grub > /dev/null 2>&1
    check_success "GRUB updated (Reboot required)" "Failed to update GRUB"
fi

# ------------------------
# 3. Install Wings
# ------------------------
print_status "Installing Pterodactyl Wings"

sudo mkdir -p /etc/pterodactyl

ARCH="$(uname -m)"
if [[ "$ARCH" == "x86_64" ]]; then
    BIN_ARCH="amd64"
else
    BIN_ARCH="arm64"
fi

curl -L -o /usr/local/bin/wings \
"https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${BIN_ARCH}"
check_success "Wings downloaded" "Failed to download Wings"

sudo chmod +x /usr/local/bin/wings

# ------------------------
# 4. Create systemd Service
# ------------------------
print_status "Creating wings.service"

cat <<SERVICE | sudo tee /etc/systemd/system/wings.service > /dev/null
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
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable wings
check_success "Wings service registered" "Failed to enable Wings"

# ------------------------
# 5. Generate SSL Certificates
# ------------------------
print_status "Generating SSL certificates"

sudo mkdir -p /etc/certs/wings
cd /etc/certs/wings

openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
-subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
-keyout privkey.pem -out fullchain.pem

check_success "SSL certificates generated" "SSL generation failed"

# ------------------------
# 6. Collect Wings Credentials
# ------------------------
echo
read -p "Enter Wings UUID: " UUID
read -p "Enter Token ID: " TOKEN_ID
read -p "Enter Token: " TOKEN
read -p "Enter Remote URL (Panel URL): " REMOTE

# ------------------------
# 7. Create Wings Config
# ------------------------
print_status "Creating Wings configuration"

cat <<CFG | sudo tee /etc/pterodactyl/config.yml > /dev/null
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

check_success "Wings config created" "Failed to write config"

# ------------------------
# 8. Start Wings
# ------------------------
print_status "Starting Wings"
sudo systemctl start wings
check_success "Wings started successfully" "Wings failed to start"

echo
echo "✅ Pterodactyl Wings installation complete"
echo "⚠️ Reboot required if GRUB was modified"
