#!/bin/bash

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Formatting
BLUE='\e[34m'
GREEN='\e[32m'
RED='\e[31m'
NC='\e[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
check_success() { if [ $? -eq 0 ]; then echo -e "${GREEN}[SUCCESS]${NC} $1"; else echo -e "${RED}[ERROR]${NC} $2"; exit 1; fi }

# Progress Bar Function for smaller tasks
run_with_bar() {
    local message=$1
    local command=$2
    echo -ne "${BLUE}[INFO]${NC} $message... [                          ] (0%) \r"
    eval "$command" > /dev/null 2>&1 &
    local pid=$!
    local count=0
    while kill -0 $pid 2>/dev/null; do
        count=$(( (count + 1) % 26 ))
        local bar=""
        for ((i=0; i<count; i++)); do bar+="#"; done
        for ((i=count; i<25; i++)); do bar+=" "; done
        echo -ne "${BLUE}[INFO]${NC} $message... [${bar}] ($((count * 4))%) \r"
        sleep 0.2
    done
    wait $pid
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[SUCCESS]${NC} $message... [#########################] (100%)"
    else
        echo -e "${RED}[ERROR]${NC} $message failed."
        exit 1
    fi
}

# --- START INSTALLATION ---

# 1. Install Docker (LOGS ENABLED)
print_status "Starting Docker installation (Detailed logs below)..."
echo "-------------------------------------------------------"
# Running without /dev/null so you see the live progress
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
echo "-------------------------------------------------------"
systemctl enable --now docker > /dev/null 2>&1
check_success "Docker Engine active" "Docker failed to start"

# 2. Update GRUB (Swap Support)
GRUB_FILE="/etc/default/grub"
if [ -f "$GRUB_FILE" ] && ! grep -q "swapaccount=1" "$GRUB_FILE"; then
    print_status "Enabling Docker swap accounting in GRUB..."
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&swapaccount=1 /' $GRUB_FILE
    update-grub > /dev/null 2>&1
    print_status "GRUB updated. A reboot will be required later."
fi

# 3. Download Wings (PROGRESS BAR)
run_with_bar "Downloading Wings binary" "mkdir -p /etc/pterodactyl && ARCH=\$([[ \"\$(uname -m)\" == \"x86_64\" ]] && echo \"amd64\" || echo \"arm64\") && curl -L -s -o /usr/local/bin/wings \"https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_\$ARCH\" && chmod u+x /usr/local/bin/wings"

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

# 5. Generate SSL (PROGRESS BAR)
run_with_bar "Generating SSL certificates" "mkdir -p /etc/certs/wings && openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj '/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate' -keyout /etc/certs/wings/privkey.pem -out /etc/certs/wings/fullchain.pem"

# 6. Configuration (INTERACTIVE)
echo "-------------------------------------------------------"
echo "Configure Wings with details from your Panel:"
read -p "Node UUID: " UUID < /dev/tty
read -p "Token ID: " TOKEN_ID < /dev/tty
read -p "Token: " TOKEN < /dev/tty
read -p "Remote URL: " REMOTE < /dev/tty
echo "-------------------------------------------------------"

# 7. Finalize
print_status "Writing configuration and starting service..."
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

systemctl start wings > /dev/null 2>&1
check_success "Wings is now flying!" "Wings failed to start. Run 'journalctl -u wings' for info."
