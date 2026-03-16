#!/bin/bash

# =============================================================================
# 01-vps-setup.sh
# Generic VPS Hardening + Docker Install
# Ubuntu Server 24.04 LTS
# -----------------------------------------------------------------------------
# Run this FIRST on any fresh VPS before deploying any app.
# Creates a secure deploy user, hardens SSH, configures firewall,
# installs Docker, nginx, and Certbot.
# =============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[✔]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✘]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $1${NC}\n${BLUE}══════════════════════════════════════${NC}\n"; }

# --- Must run as root ---
[ "$EUID" -ne 0 ] && error "Run as root: sudo bash 01-vps-setup.sh"

# --- Ubuntu 24.04 check ---
. /etc/os-release
[ "$ID" != "ubuntu" ] && warn "This script is tested on Ubuntu. Proceed with caution on $ID."

# =============================================================================
# COLLECT INFORMATION
# =============================================================================
section "VPS Setup — Gathering Information"

echo "This script sets up a secure base environment for any Dockerized app."
echo "Answer the following questions to continue."
echo ""

# Deploy username
read -p "Enter a name for the deploy user (e.g. deploy): " DEPLOY_USER
[[ -z "$DEPLOY_USER" || "$DEPLOY_USER" =~ [^a-z0-9_-] ]] && error "Username must be lowercase letters, numbers, hyphens or underscores only."

# Deploy user password
while true; do
  read -s -p "Set a password for '$DEPLOY_USER': " DEPLOY_PASS; echo ""
  read -s -p "Confirm password: " DEPLOY_PASS2; echo ""
  [ ${#DEPLOY_PASS} -lt 12 ] && warn "Password must be at least 12 characters." && continue
  [ "$DEPLOY_PASS" = "$DEPLOY_PASS2" ] && break
  warn "Passwords do not match. Try again."
done

# SSH port
read -p "SSH port (press ENTER for default 22, or choose a custom port e.g. 2222): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}
[[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ] && error "Invalid port number."

# Timezone
read -p "Server timezone (e.g. Africa/Lusaka, press ENTER for UTC): " TZ_INPUT
TZ_INPUT=${TZ_INPUT:-UTC}

echo ""
log "Information collected. Starting setup..."
sleep 1

# =============================================================================
# SYSTEM UPDATE
# =============================================================================
section "Updating System"

export DEBIAN_FRONTEND=noninteractive
apt update -y && apt upgrade -y
apt install -y \
  curl wget git ufw fail2ban \
  unattended-upgrades apt-listchanges \
  gnupg2 ca-certificates lsb-release \
  apt-transport-https software-properties-common \
  logwatch libpam-pwquality \
  nginx certbot python3-certbot-nginx \
  net-tools htop unzip
log "System packages installed."

# Set timezone
timedatectl set-timezone "$TZ_INPUT"
log "Timezone set to $TZ_INPUT."

# =============================================================================
# CREATE DEPLOY USER
# =============================================================================
section "Creating Deploy User: $DEPLOY_USER"

if id "$DEPLOY_USER" &>/dev/null; then
  warn "User '$DEPLOY_USER' already exists, skipping creation."
else
  useradd -m -s /bin/bash "$DEPLOY_USER"
  echo "$DEPLOY_USER:$DEPLOY_PASS" | chpasswd
  usermod -aG sudo "$DEPLOY_USER"
  log "User '$DEPLOY_USER' created and added to sudo group."
fi

# Create .ssh directory for deploy user
DEPLOY_HOME="/home/$DEPLOY_USER"
mkdir -p "$DEPLOY_HOME/.ssh"
chmod 700 "$DEPLOY_HOME/.ssh"
touch "$DEPLOY_HOME/.ssh/authorized_keys"
chmod 600 "$DEPLOY_HOME/.ssh/authorized_keys"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_HOME/.ssh"
log "SSH directory created for $DEPLOY_USER."

# =============================================================================
# SSH HARDENING
# =============================================================================
section "Hardening SSH"

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d)"

# Write a clean hardened SSH config
cat > /etc/ssh/sshd_config.d/99-hardened.conf << EOF
# SpotRev VPS — Hardened SSH Config

# Disable root login completely
PermitRootLogin no

# Only allow deploy user
AllowUsers $DEPLOY_USER

# Use custom port if specified
Port $SSH_PORT

# Authentication
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30s
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no

# Disable unused auth methods
KerberosAuthentication no
GSSAPIAuthentication no
UsePAM yes

# Disable X11 and agent forwarding (not needed on a server)
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no

# Show last login on connect
PrintLastLog yes

# Drop idle connections after 5 minutes
ClientAliveInterval 300
ClientAliveCountMax 2

# Use strong crypto only
Protocol 2
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com
KexAlgorithms curve25519-sha256,diffie-hellman-group16-sha512
EOF

systemctl restart ssh
log "SSH hardened. Root login disabled. Port set to $SSH_PORT."
warn "Remember: SSH in as '$DEPLOY_USER' on port $SSH_PORT from now on."

# =============================================================================
# FIREWALL (UFW)
# =============================================================================
section "Configuring Firewall (UFW)"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH on chosen port
ufw allow "$SSH_PORT/tcp" comment "SSH"
ufw allow 80/tcp comment "HTTP"
ufw allow 443/tcp comment "HTTPS"

# Rate limit SSH to slow brute force
ufw limit "$SSH_PORT/tcp" comment "SSH rate limit"

ufw --force enable
log "Firewall enabled. Open ports: $SSH_PORT (SSH), 80 (HTTP), 443 (HTTPS)."

# =============================================================================
# FAIL2BAN
# =============================================================================
section "Configuring Fail2ban"

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
# Ban for 24 hours after 3 failed attempts within 10 minutes
bantime   = 24h
findtime  = 10m
maxretry  = 3
banaction = ufw

# Email alerts (optional — set destemail to your email)
# destemail = you@example.com
# action = %(action_mwl)s

[sshd]
enabled  = true
port     = $SSH_PORT
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3
bantime  = 72h

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled  = true
port     = http,https
logpath  = %(nginx_error_log)s
maxretry = 2
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2ban configured. SSH and nginx brute force protection active."

# =============================================================================
# AUTOMATIC SECURITY UPDATES
# =============================================================================
section "Configuring Automatic Security Updates"

cat > /etc/apt/apt.conf.d/50unattended-upgrades << EOF
Unattended-Upgrade::Allowed-Origins {
  "\${distro_id}:\${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable unattended-upgrades
systemctl restart unattended-upgrades
log "Automatic security updates enabled."

# =============================================================================
# KERNEL & NETWORK HARDENING (sysctl)
# =============================================================================
section "Hardening Kernel Network Settings"

cat > /etc/sysctl.d/99-vps-hardening.conf << EOF
# Ignore ICMP ping broadcasts
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 4096

# Disable IP source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Enable reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Log suspicious packets
net.ipv4.conf.all.log_martians = 1

# Disable IPv6 if not needed
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

sysctl --system > /dev/null 2>&1
log "Kernel network hardening applied."

# =============================================================================
# PASSWORD POLICY
# =============================================================================
section "Enforcing Password Policy"

cat > /etc/security/pwquality.conf << EOF
minlen = 12
minclass = 3
maxrepeat = 3
gecoscheck = 1
EOF

log "Password policy enforced (min 12 chars, 3 character classes)."

# =============================================================================
# INSTALL DOCKER
# =============================================================================
section "Installing Docker"

if command -v docker &>/dev/null; then
  warn "Docker already installed. Skipping."
else
  curl -fsSL https://get.docker.com | bash
  log "Docker installed."
fi

# Add deploy user to docker group
usermod -aG docker "$DEPLOY_USER"

# Install Docker Compose plugin
apt install -y docker-compose-plugin

# Harden Docker daemon
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "no-new-privileges": true
}
EOF

systemctl enable docker
systemctl restart docker
log "Docker installed and hardened."

# =============================================================================
# CONFIGURE NGINX (secure defaults)
# =============================================================================
section "Configuring nginx Secure Defaults"

# Hide nginx version
sed -i 's/# server_tokens off;/server_tokens off;/' /etc/nginx/nginx.conf

# Global security headers snippet
cat > /etc/nginx/snippets/security-headers.conf << EOF
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
EOF

# Proxy settings snippet (reusable by any app)
cat > /etc/nginx/snippets/proxy-params.conf << EOF
proxy_http_version 1.1;
proxy_set_header Upgrade \$http_upgrade;
proxy_set_header Connection 'upgrade';
proxy_set_header Host \$host;
proxy_set_header X-Real-IP \$remote_addr;
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto \$scheme;
proxy_cache_bypass \$http_upgrade;
proxy_read_timeout 60s;
proxy_connect_timeout 60s;
EOF

rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
log "nginx secure defaults configured."

# =============================================================================
# LOGWATCH (Daily Security Digest)
# =============================================================================
section "Configuring Logwatch"

cat > /etc/logwatch/conf/logwatch.conf << EOF
Output = mail
Format = text
Encode = none
MailTo = root
MailFrom = logwatch@$(hostname)
Range = yesterday
Detail = Low
Service = All
EOF

log "Logwatch configured. Daily security digest will be sent to root."

# =============================================================================
# USEFUL ADMIN SCRIPTS
# =============================================================================
section "Creating Admin Utility Scripts"

# Script to open a port for a new app
cat > /usr/local/bin/vps-open-port << 'EOF'
#!/bin/bash
[ -z "$1" ] && echo "Usage: vps-open-port <port>" && exit 1
ufw allow "$1/tcp"
echo "Port $1 opened."
ufw status
EOF
chmod +x /usr/local/bin/vps-open-port

# Script to add a new user
cat > /usr/local/bin/vps-add-user << EOF
#!/bin/bash
[ -z "\$1" ] && echo "Usage: vps-add-user <username>" && exit 1
USERNAME=\$1
useradd -m -s /bin/bash "\$USERNAME"
passwd "\$USERNAME"
read -p "Give sudo access? (yes/no): " SUDO_ACCESS
[ "\$SUDO_ACCESS" = "yes" ] && usermod -aG sudo "\$USERNAME" && echo "Sudo access granted."
# Allow SSH access
sed -i "s/^AllowUsers.*/& \$USERNAME/" /etc/ssh/sshd_config.d/99-hardened.conf
systemctl restart ssh
echo "User '\$USERNAME' created and SSH access granted."
EOF
chmod +x /usr/local/bin/vps-add-user

# Script to check server health
cat > /usr/local/bin/vps-status << 'EOF'
#!/bin/bash
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VPS STATUS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Uptime    : $(uptime -p)"
echo "  Memory    : $(free -h | awk '/^Mem/{print $3 " used / " $2 " total"}')"
echo "  Disk      : $(df -h / | awk 'NR==2{print $3 " used / " $2 " total (" $5 " full)"}')"
echo "  CPU Load  : $(cut -d' ' -f1-3 /proc/loadavg)"
echo "  Public IP : $(curl -s ifconfig.me)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DOCKER CONTAINERS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker ps --format "  {{.Names}}\t{{.Status}}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  FIREWALL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ufw status numbered
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  BANNED IPs (Fail2ban)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fail2ban-client status sshd 2>/dev/null | grep "Banned IP" || echo "  None"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
EOF
chmod +x /usr/local/bin/vps-status

log "Admin utilities created: vps-open-port, vps-add-user, vps-status"

# =============================================================================
# DONE
# =============================================================================
section "VPS Setup Complete!"

PUBLIC_IP=$(curl -s ifconfig.me)

echo -e "${GREEN}Your VPS is now hardened and Docker-ready.${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Server IP     : $PUBLIC_IP"
echo "  Deploy user   : $DEPLOY_USER"
echo "  SSH port      : $SSH_PORT"
echo "  Timezone      : $TZ_INPUT"
echo ""
echo "  SECURITY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [✔] Root SSH login disabled"
echo "  [✔] SSH hardened (port $SSH_PORT, strong ciphers)"
echo "  [✔] UFW firewall (SSH, HTTP, HTTPS only)"
echo "  [✔] Fail2ban (SSH + nginx protection)"
echo "  [✔] Auto security updates"
echo "  [✔] Kernel network hardening"
echo "  [✔] Docker daemon hardened"
echo "  [✔] Password policy enforced"
echo ""
echo "  ADMIN COMMANDS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Server status   : vps-status"
echo "  Add a user      : sudo vps-add-user <username>"
echo "  Open a port     : sudo vps-open-port <port>"
echo ""
echo "  NEXT STEP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SSH back in as: ssh $DEPLOY_USER@$PUBLIC_IP -p $SSH_PORT"
echo "  Then run:       bash 02-spotrev-install.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
warn "Log out and back in as '$DEPLOY_USER' — root SSH is now disabled."
