#!/bin/bash

# =============================================================================
# 01-vps-harden.sh
# OS Security Hardening for Ubuntu Server
# =============================================================================
#
# PURPOSE:
#   Lock down a fresh Ubuntu server with security best practices.
#   Creates a deploy user, hardens SSH, configures firewall, sets up
#   intrusion detection, and enables automatic security updates.
#
# DEPENDENCIES:
#   None — run this first on a fresh server.
#
# NEXT STEP:
#   Run 02-docker-install.sh to install Docker.
#
# USAGE:
#   sudo bash 01-vps-harden.sh
#
# SAFE TO RE-RUN:
#   Yes — detects existing configuration and asks before overwriting.
#
# =============================================================================

set -euo pipefail

# --- Colors & Logging (self-contained) ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!!]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $1${NC}\n${BLUE}══════════════════════════════════════${NC}\n"; }

# --- Detect public/local IP (works on VPS and VirtualBox) ---
get_server_ip() {
  local ip
  ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null) || true
  if [ -z "$ip" ]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  fi
  echo "${ip:-unknown}"
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

# Must run as root
[ "$EUID" -ne 0 ] && error "This script must be run as root. Use: sudo bash 01-vps-harden.sh"

# OS check
if [ -f /etc/os-release ]; then
  . /etc/os-release
  if [ "$ID" != "ubuntu" ]; then
    warn "This script is tested on Ubuntu. You are running $ID $VERSION_ID."
    read -p "Continue anyway? (y/n): " OS_CONTINUE
    [ "$OS_CONTINUE" != "y" ] && echo "Aborted." && exit 0
  fi
else
  warn "Cannot detect OS. Proceeding with caution."
fi

# =============================================================================
# WELCOME BANNER
# =============================================================================
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  VPS HARDENING SCRIPT${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  This script will:"
echo "    1. Create a secure deploy user"
echo "    2. Harden SSH access"
echo "    3. Configure UFW firewall"
echo "    4. Set up Fail2ban intrusion detection"
echo "    5. Enable automatic security updates"
echo "    6. Harden kernel network settings"
echo "    7. Enforce password policy"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

read -p "Ready to begin? (y/n): " START_CONFIRM
[ "$START_CONFIRM" != "y" ] && echo "Aborted." && exit 0

# =============================================================================
# GATHER INFORMATION
# =============================================================================
section "Step 1/7 — Gathering Information"

# Deploy username
read -p "Enter a name for the deploy user (e.g. deploy): " DEPLOY_USER
[[ -z "$DEPLOY_USER" || "$DEPLOY_USER" =~ [^a-z0-9_-] ]] && error "Username must be lowercase letters, numbers, hyphens or underscores only."

# Deploy user password
while true; do
  read -s -p "Set a password for '$DEPLOY_USER': " DEPLOY_PASS; echo ""
  read -s -p "Confirm password: " DEPLOY_PASS2; echo ""
  [ ${#DEPLOY_PASS} -lt 12 ] && warn "Password must be at least 12 characters. Try again." && continue
  [ "$DEPLOY_PASS" = "$DEPLOY_PASS2" ] && break
  warn "Passwords do not match. Try again."
done

# SSH port
read -p "SSH port (press ENTER for default 22, or choose a custom port e.g. 2222): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}
[[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] && error "Invalid port number."
[ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ] || true
[[ "$SSH_PORT" -lt 1 || "$SSH_PORT" -gt 65535 ]] && error "Port must be between 1 and 65535."

# Timezone
read -p "Server timezone (e.g. Africa/Lusaka, press ENTER for UTC): " TZ_INPUT
TZ_INPUT=${TZ_INPUT:-UTC}

echo ""
log "Information collected. Starting hardening..."
sleep 1

# =============================================================================
# SYSTEM UPDATE
# =============================================================================
section "Step 2/7 — Updating System Packages"

echo "Updating package lists and installing security tools..."
echo "This may take a few minutes."
echo ""

export DEBIAN_FRONTEND=noninteractive
apt update -y && apt upgrade -y

apt install -y \
  openssh-server \
  curl wget git ufw fail2ban \
  unattended-upgrades apt-listchanges \
  gnupg2 ca-certificates lsb-release \
  apt-transport-https software-properties-common \
  logwatch libpam-pwquality \
  net-tools htop unzip

log "System packages updated and security tools installed."

# Set timezone
timedatectl set-timezone "$TZ_INPUT"
log "Timezone set to $TZ_INPUT."

# =============================================================================
# CREATE DEPLOY USER
# =============================================================================
section "Step 3/7 — Creating Deploy User: $DEPLOY_USER"

if id "$DEPLOY_USER" &>/dev/null; then
  warn "User '$DEPLOY_USER' already exists."
  read -p "Reconfigure this user? (y/n): " RECONFIG_USER
  if [ "$RECONFIG_USER" = "y" ]; then
    echo "$DEPLOY_USER:$DEPLOY_PASS" | chpasswd
    usermod -aG sudo "$DEPLOY_USER"
    log "Password updated and sudo access confirmed for '$DEPLOY_USER'."
  else
    log "Skipping user reconfiguration."
  fi
else
  useradd -m -s /bin/bash "$DEPLOY_USER"
  echo "$DEPLOY_USER:$DEPLOY_PASS" | chpasswd
  usermod -aG sudo "$DEPLOY_USER"
  log "User '$DEPLOY_USER' created and added to sudo group."
fi

# Ensure .ssh directory exists
DEPLOY_HOME="/home/$DEPLOY_USER"
mkdir -p "$DEPLOY_HOME/.ssh"
chmod 700 "$DEPLOY_HOME/.ssh"
touch "$DEPLOY_HOME/.ssh/authorized_keys"
chmod 600 "$DEPLOY_HOME/.ssh/authorized_keys"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_HOME/.ssh"
log "SSH directory configured for '$DEPLOY_USER'."

# =============================================================================
# SSH HARDENING
# =============================================================================
section "Step 4/7 — Hardening SSH"

SSHD_HARDENED="/etc/ssh/sshd_config.d/99-hardened.conf"

if [ -f "$SSHD_HARDENED" ]; then
  warn "SSH hardening config already exists."
  read -p "Overwrite with new settings? (y/n): " RECONFIG_SSH
  if [ "$RECONFIG_SSH" != "y" ]; then
    log "Skipping SSH hardening."
  fi
else
  RECONFIG_SSH="y"
fi

if [ "${RECONFIG_SSH:-y}" = "y" ]; then
  # Backup original sshd_config
  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d)" 2>/dev/null || true

  # Ensure sshd_config includes the .d/ directory (some distros don't by default)
  # Check for both uncommented and commented Include lines
  if grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
    log "Include directive already present in sshd_config."
  else
    # Uncomment existing Include if present, otherwise add it at the top
    if grep -qE '^\s*#\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
      sed -i 's/^\s*#\s*\(Include\s\+\/etc\/ssh\/sshd_config\.d\/.*\)/\1/' /etc/ssh/sshd_config
      log "Uncommented Include directive in sshd_config."
    else
      sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
      log "Added Include directive for sshd_config.d/ to sshd_config."
    fi
  fi

  # Ensure the drop-in directory exists
  mkdir -p /etc/ssh/sshd_config.d

  cat > "$SSHD_HARDENED" << EOF
# VPS Hardened SSH Config — generated by 01-vps-harden.sh

# Disable root login
PermitRootLogin no

# Only allow deploy user
AllowUsers $DEPLOY_USER

# Custom SSH port
Port $SSH_PORT

# Authentication limits
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

# Disable forwarding (not needed on a server)
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no

# Show last login on connect
PrintLastLog yes

# Drop idle connections after 5 minutes
ClientAliveInterval 300
ClientAliveCountMax 2

# Strong ciphers only
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com
KexAlgorithms curve25519-sha256,diffie-hellman-group16-sha512
EOF

  # Validate config before restarting
  if ! sshd -t 2>/dev/null; then
    warn "SSH config test failed. Check $SSHD_HARDENED for errors."
    sshd -t
  fi

  # Restart SSH — service name varies by distro (ssh on Ubuntu, sshd on others)
  if systemctl is-active --quiet ssh 2>/dev/null; then
    systemctl restart ssh
  elif systemctl is-active --quiet sshd 2>/dev/null; then
    systemctl restart sshd
  else
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || warn "Could not restart SSH service."
  fi

  # Verify the new port is actually listening
  sleep 1
  if ss -tlnp | grep -q ":${SSH_PORT} "; then
    log "SSH is now listening on port $SSH_PORT."
  else
    warn "SSH does NOT appear to be listening on port $SSH_PORT!"
    warn "Check: sudo ss -tlnp | grep ssh"
    warn "Check: sudo sshd -t"
  fi

  log "SSH hardened successfully."
  log "  Root login: DISABLED"
  log "  Allowed user: $DEPLOY_USER"
  log "  Port: $SSH_PORT"
  log "  Strong ciphers: ENABLED"
  warn "From now on, SSH in as '$DEPLOY_USER' on port $SSH_PORT."
fi

# =============================================================================
# FIREWALL (UFW)
# =============================================================================
section "Step 5/7 — Configuring Firewall (UFW)"

if ufw status | grep -q "Status: active"; then
  warn "UFW firewall is already active."
  read -p "Reconfigure firewall rules? (y/n): " RECONFIG_UFW
else
  RECONFIG_UFW="y"
fi

if [ "${RECONFIG_UFW:-y}" = "y" ]; then
  echo "Setting up firewall rules..."

  ufw --force reset > /dev/null 2>&1
  ufw default deny incoming > /dev/null 2>&1
  ufw default allow outgoing > /dev/null 2>&1

  # Open essential ports
  ufw allow "$SSH_PORT/tcp" comment "SSH" > /dev/null 2>&1
  ufw allow 80/tcp comment "HTTP" > /dev/null 2>&1
  ufw allow 443/tcp comment "HTTPS" > /dev/null 2>&1

  # Rate limit SSH to slow brute force
  ufw limit "$SSH_PORT/tcp" comment "SSH rate limit" > /dev/null 2>&1

  ufw --force enable > /dev/null 2>&1

  log "Firewall enabled."
  log "  Open ports: $SSH_PORT (SSH), 80 (HTTP), 443 (HTTPS)"
  log "  SSH rate limiting: ENABLED"
  log "  Default incoming: DENY"
  log "  Default outgoing: ALLOW"

  # Also configure Fail2ban
  echo ""
  echo "Configuring Fail2ban intrusion detection..."

  if [ -f /etc/fail2ban/jail.local ]; then
    warn "Fail2ban config already exists."
    read -p "Overwrite? (y/n): " RECONFIG_F2B
  else
    RECONFIG_F2B="y"
  fi

  if [ "${RECONFIG_F2B:-y}" = "y" ]; then
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
# Ban for 24 hours after 3 failed attempts within 10 minutes
bantime   = 24h
findtime  = 10m
maxretry  = 3
banaction = ufw

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

    systemctl enable fail2ban > /dev/null 2>&1
    systemctl restart fail2ban
    log "Fail2ban configured."
    log "  SSH: 3 failed attempts = 72h ban"
    log "  Nginx: bot/auth protection enabled"
  else
    log "Skipping Fail2ban reconfiguration."
  fi
else
  log "Skipping firewall reconfiguration."
fi

# =============================================================================
# AUTOMATIC SECURITY UPDATES
# =============================================================================
section "Step 6/7 — Configuring Automatic Security Updates"

if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
  warn "Unattended upgrades config already exists."
  read -p "Overwrite? (y/n): " RECONFIG_UPDATES
else
  RECONFIG_UPDATES="y"
fi

if [ "${RECONFIG_UPDATES:-y}" = "y" ]; then
  cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
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

  systemctl enable unattended-upgrades > /dev/null 2>&1
  systemctl restart unattended-upgrades
  log "Automatic security updates enabled."
  log "  Security patches: applied daily"
  log "  Package lists: updated daily"
  log "  Auto cleanup: every 7 days"
  log "  Auto reboot: DISABLED (manual reboot required for kernel updates)"
else
  log "Skipping auto-updates reconfiguration."
fi

# =============================================================================
# KERNEL & NETWORK HARDENING + PASSWORD POLICY
# =============================================================================
section "Step 7/7 — Kernel Hardening & Password Policy"

# --- Kernel/Network Hardening ---
echo "Applying kernel network hardening..."

if [ -f /etc/sysctl.d/99-vps-hardening.conf ]; then
  warn "Kernel hardening config already exists."
  read -p "Overwrite? (y/n): " RECONFIG_SYSCTL
else
  RECONFIG_SYSCTL="y"
fi

if [ "${RECONFIG_SYSCTL:-y}" = "y" ]; then
  # Check if IPv6 is actively in use before disabling
  DISABLE_IPV6=1
  if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
    warn "Active IPv6 addresses detected. Keeping IPv6 enabled."
    DISABLE_IPV6=0
  fi

  cat > /etc/sysctl.d/99-vps-hardening.conf << EOF
# VPS Kernel Hardening — generated by 01-vps-harden.sh

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

# IPv6
net.ipv6.conf.all.disable_ipv6 = $DISABLE_IPV6
net.ipv6.conf.default.disable_ipv6 = $DISABLE_IPV6
EOF

  sysctl --system > /dev/null 2>&1
  log "Kernel network hardening applied."
  if [ "$DISABLE_IPV6" -eq 1 ]; then
    log "  IPv6: DISABLED (not in use)"
  else
    log "  IPv6: KEPT ENABLED (active addresses detected)"
  fi
else
  log "Skipping kernel hardening reconfiguration."
fi

# --- Password Policy ---
echo ""
echo "Enforcing password policy..."

cat > /etc/security/pwquality.conf << EOF
minlen = 12
minclass = 3
maxrepeat = 3
gecoscheck = 1
EOF

log "Password policy enforced."
log "  Minimum length: 12 characters"
log "  Character classes required: 3"

# --- Logwatch ---
echo ""
echo "Configuring Logwatch security reports..."

mkdir -p /etc/logwatch/conf
cat > /etc/logwatch/conf/logwatch.conf << EOF
# Output to stdout by default (change to 'mail' if you have a mail server)
Output = stdout
Format = text
Encode = none
MailTo = root
MailFrom = logwatch@$(hostname)
Range = yesterday
Detail = Low
Service = All
EOF

log "Logwatch configured (daily security digest to stdout)."

# =============================================================================
# DONE
# =============================================================================
SERVER_IP=$(get_server_ip)

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  VPS HARDENING COMPLETE${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Server IP     : $SERVER_IP"
echo "  Deploy user   : $DEPLOY_USER"
echo "  SSH port      : $SSH_PORT"
echo "  Timezone      : $TZ_INPUT"
echo ""
echo "  WHAT WAS CONFIGURED"
echo "  ───────────────────────────────────────────────"
echo "  [OK] Deploy user '$DEPLOY_USER' created"
echo "  [OK] SSH hardened (root disabled, port $SSH_PORT)"
echo "  [OK] UFW firewall (SSH, HTTP, HTTPS)"
echo "  [OK] Fail2ban intrusion detection"
echo "  [OK] Automatic security updates"
echo "  [OK] Kernel network hardening"
echo "  [OK] Password policy enforced"
echo ""
echo "  NEXT STEPS"
echo "  ───────────────────────────────────────────────"
echo "  1. Log out of root"
echo "  2. SSH back in as: ssh $DEPLOY_USER@$SERVER_IP -p $SSH_PORT"
echo "  3. Run: sudo bash 02-docker-install.sh"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
warn "Root SSH login is now DISABLED. Make sure you can log in as '$DEPLOY_USER' before closing this session."
