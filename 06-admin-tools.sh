#!/bin/bash

# =============================================================================
# 06-admin-tools.sh
# Install VPS Admin Utility Commands
# =============================================================================
#
# PURPOSE:
#   Install a set of handy command-line utilities for managing your VPS.
#   These are installed to /usr/local/bin/ so they're available system-wide.
#
# DEPENDENCIES:
#   Recommends 01-vps-harden.sh (for UFW/fail2ban reporting) and
#   02-docker-install.sh (for Docker status). Works without them but
#   some output will be incomplete.
#
# USAGE:
#   sudo bash 06-admin-tools.sh
#
# SAFE TO RE-RUN:
#   Yes — asks before overwriting existing commands.
#
# COMMANDS INSTALLED:
#   vps-status        — Server health dashboard
#   vps-open-port     — Open a UFW firewall port
#   vps-close-port    — Close a UFW firewall port
#   vps-add-user      — Add a system user with optional sudo + SSH
#   vps-list-apps     — List all deployed apps with status
#   vps-logs          — Tail Docker logs for a deployed app
#   vps-restart       — Restart a deployed app's containers
#   vps-remove-app    — Completely remove a deployed app
#
# =============================================================================

set -euo pipefail

# --- Colors & Logging (self-contained) ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!!]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $1${NC}\n${BLUE}══════════════════════════════════════${NC}\n"; }

# Helper to install a command
install_cmd() {
  local CMD_NAME="$1"
  local CMD_PATH="/usr/local/bin/$CMD_NAME"

  if [ -f "$CMD_PATH" ]; then
    warn "$CMD_NAME already exists."
    read -p "  Overwrite? (y/n): " OVERWRITE
    if [ "$OVERWRITE" != "y" ]; then
      log "Skipping $CMD_NAME."
      return 1
    fi
  fi
  return 0
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

[ "$EUID" -ne 0 ] && error "This script must be run as root. Use: sudo bash 06-admin-tools.sh"

# Detect deploy user for apps directory path
DEPLOY_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home/ {print $1; exit}' /etc/passwd)
DEPLOY_HOME="/home/${DEPLOY_USER:-deploy}"
APPS_DIR="$DEPLOY_HOME/apps"

# =============================================================================
# WELCOME BANNER
# =============================================================================
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  ADMIN TOOLS INSTALLATION${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  This script will install these commands:"
echo "    vps-status      — Server health dashboard"
echo "    vps-open-port   — Open a firewall port"
echo "    vps-close-port  — Close a firewall port"
echo "    vps-add-user    — Add a system user"
echo "    vps-list-apps   — List deployed apps"
echo "    vps-logs        — View app logs"
echo "    vps-restart     — Restart an app"
echo "    vps-remove-app  — Remove a deployed app"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

read -p "Ready to install? (y/n): " START_CONFIRM
[ "$START_CONFIRM" != "y" ] && echo "Aborted." && exit 0

# =============================================================================
# VPS-STATUS
# =============================================================================
section "Installing: vps-status"

if install_cmd "vps-status"; then
  cat > /usr/local/bin/vps-status << 'CMDEOF'
#!/bin/bash
# vps-status — Server health dashboard

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Get server IP (works on VPS and VirtualBox)
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  VPS STATUS${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Server IP  : $SERVER_IP"
echo "  Hostname   : $(hostname)"
echo "  Uptime     : $(uptime -p 2>/dev/null || echo 'unknown')"
echo "  Memory     : $(free -h 2>/dev/null | awk '/^Mem/{print $3 " used / " $2 " total"}' || echo 'unknown')"
echo "  Disk       : $(df -h / 2>/dev/null | awk 'NR==2{print $3 " used / " $2 " total (" $5 " full)"}' || echo 'unknown')"
echo "  CPU Load   : $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo 'unknown')"
echo ""

# Docker containers
if command -v docker &>/dev/null; then
  echo -e "${BLUE}  DOCKER CONTAINERS${NC}"
  echo "  ───────────────────────────────────────────────"
  CONTAINERS=$(docker ps --format "  {{.Names}}\t{{.Status}}" 2>/dev/null)
  if [ -n "$CONTAINERS" ]; then
    echo "$CONTAINERS"
  else
    echo "  No running containers"
  fi
  echo ""
fi

# Firewall
if command -v ufw &>/dev/null; then
  echo -e "${BLUE}  FIREWALL${NC}"
  echo "  ───────────────────────────────────────────────"
  ufw status 2>/dev/null | grep -v "^$" | sed 's/^/  /'
  echo ""
fi

# Fail2ban
if command -v fail2ban-client &>/dev/null; then
  echo -e "${BLUE}  BANNED IPs (Fail2ban)${NC}"
  echo "  ───────────────────────────────────────────────"
  BANNED=$(fail2ban-client status sshd 2>/dev/null | grep "Banned IP" || echo "  None")
  echo "  $BANNED"
  echo ""
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
CMDEOF
  chmod +x /usr/local/bin/vps-status
  log "vps-status installed."
fi

# =============================================================================
# VPS-OPEN-PORT
# =============================================================================
section "Installing: vps-open-port"

if install_cmd "vps-open-port"; then
  cat > /usr/local/bin/vps-open-port << 'CMDEOF'
#!/bin/bash
# vps-open-port — Open a UFW firewall port

if [ -z "$1" ]; then
  echo "Usage: vps-open-port <port>"
  echo "Example: vps-open-port 8080"
  exit 1
fi

if ! command -v ufw &>/dev/null; then
  echo "Error: UFW is not installed."
  exit 1
fi

PORT="$1"
echo "Opening port $PORT/tcp..."
sudo ufw allow "$PORT/tcp"
echo ""
echo "Current firewall status:"
sudo ufw status numbered
CMDEOF
  chmod +x /usr/local/bin/vps-open-port
  log "vps-open-port installed."
fi

# =============================================================================
# VPS-CLOSE-PORT
# =============================================================================
section "Installing: vps-close-port"

if install_cmd "vps-close-port"; then
  cat > /usr/local/bin/vps-close-port << 'CMDEOF'
#!/bin/bash
# vps-close-port — Close a UFW firewall port

if [ -z "$1" ]; then
  echo "Usage: vps-close-port <port>"
  echo "Example: vps-close-port 8080"
  exit 1
fi

if ! command -v ufw &>/dev/null; then
  echo "Error: UFW is not installed."
  exit 1
fi

PORT="$1"
echo "Closing port $PORT/tcp..."
sudo ufw deny "$PORT/tcp"
echo ""
echo "Current firewall status:"
sudo ufw status numbered
CMDEOF
  chmod +x /usr/local/bin/vps-close-port
  log "vps-close-port installed."
fi

# =============================================================================
# VPS-ADD-USER
# =============================================================================
section "Installing: vps-add-user"

if install_cmd "vps-add-user"; then
  cat > /usr/local/bin/vps-add-user << 'CMDEOF'
#!/bin/bash
# vps-add-user — Add a new system user with optional sudo + SSH access

if [ "$EUID" -ne 0 ]; then
  echo "Error: Must run as root. Use: sudo vps-add-user <username>"
  exit 1
fi

if [ -z "$1" ]; then
  echo "Usage: sudo vps-add-user <username>"
  echo "Example: sudo vps-add-user john"
  exit 1
fi

USERNAME="$1"

if id "$USERNAME" &>/dev/null; then
  echo "Error: User '$USERNAME' already exists."
  exit 1
fi

echo "Creating user '$USERNAME'..."
useradd -m -s /bin/bash "$USERNAME"
passwd "$USERNAME"

read -p "Give sudo access? (y/n): " SUDO_ACCESS
if [ "$SUDO_ACCESS" = "y" ]; then
  usermod -aG sudo "$USERNAME"
  echo "Sudo access granted."
fi

read -p "Allow SSH access? (y/n): " SSH_ACCESS
if [ "$SSH_ACCESS" = "y" ]; then
  SSHD_HARDENED="/etc/ssh/sshd_config.d/99-hardened.conf"
  if [ -f "$SSHD_HARDENED" ]; then
    sed -i "s/^AllowUsers.*/& $USERNAME/" "$SSHD_HARDENED"
    systemctl restart ssh
    echo "SSH access granted."
  else
    echo "Warning: SSH hardened config not found. User may need to be added to AllowUsers manually."
  fi
fi

read -p "Add to docker group? (y/n): " DOCKER_ACCESS
if [ "$DOCKER_ACCESS" = "y" ]; then
  if getent group docker &>/dev/null; then
    usermod -aG docker "$USERNAME"
    echo "Docker access granted."
  else
    echo "Warning: Docker group does not exist. Install Docker first."
  fi
fi

echo ""
echo "User '$USERNAME' created successfully."
echo "  Home directory: /home/$USERNAME"
echo "  Sudo: $(groups "$USERNAME" | grep -q sudo && echo 'yes' || echo 'no')"
echo "  Docker: $(groups "$USERNAME" | grep -q docker && echo 'yes' || echo 'no')"
CMDEOF
  chmod +x /usr/local/bin/vps-add-user
  log "vps-add-user installed."
fi

# =============================================================================
# VPS-LIST-APPS
# =============================================================================
section "Installing: vps-list-apps"

if install_cmd "vps-list-apps"; then
  cat > /usr/local/bin/vps-list-apps << 'CMDEOF'
#!/bin/bash
# vps-list-apps — List all deployed apps with status

DEPLOY_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home/ {print $1; exit}' /etc/passwd)
APPS_DIR="/home/$DEPLOY_USER/apps"

if [ ! -d "$APPS_DIR" ] || [ -z "$(ls -A "$APPS_DIR" 2>/dev/null)" ]; then
  echo "No apps deployed yet."
  echo "Deploy your first app with: sudo bash 04-deploy-app.sh"
  exit 0
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DEPLOYED APPS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

for app_dir in "$APPS_DIR"/*/; do
  [ ! -d "$app_dir" ] && continue
  APP=$(basename "$app_dir")
  INFO_FILE="$app_dir/.deploy-info"

  if [ -f "$INFO_FILE" ]; then
    DOMAIN=$(grep "^DOMAIN_NAME=" "$INFO_FILE" 2>/dev/null | cut -d= -f2-)
    PORT=$(grep "^APP_PORT=" "$INFO_FILE" 2>/dev/null | cut -d= -f2-)
    COMMIT=$(grep "^DEPLOYED_COMMIT=" "$INFO_FILE" 2>/dev/null | cut -d= -f2-)
    DEPLOYED=$(grep "^DEPLOYED_AT=" "$INFO_FILE" 2>/dev/null | cut -d= -f2-)

    # Check if containers are running
    STATUS="stopped"
    if cd "$app_dir" && docker compose ps 2>/dev/null | grep -q "Up\|running"; then
      STATUS="running"
    fi

    echo "  $APP"
    echo "    Status  : $STATUS"
    [ -n "$DOMAIN" ] && echo "    Domain  : $DOMAIN"
    [ -n "$PORT" ]   && echo "    Port    : $PORT"
    [ -n "$COMMIT" ] && echo "    Commit  : $COMMIT"
    [ -n "$DEPLOYED" ] && echo "    Deployed: $DEPLOYED"
    echo ""
  else
    echo "  $APP (no deploy info found)"
    echo ""
  fi
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
CMDEOF
  chmod +x /usr/local/bin/vps-list-apps
  log "vps-list-apps installed."
fi

# =============================================================================
# VPS-LOGS
# =============================================================================
section "Installing: vps-logs"

if install_cmd "vps-logs"; then
  cat > /usr/local/bin/vps-logs << 'CMDEOF'
#!/bin/bash
# vps-logs — Tail Docker logs for a deployed app

DEPLOY_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home/ {print $1; exit}' /etc/passwd)
APPS_DIR="/home/$DEPLOY_USER/apps"

if [ -z "$1" ]; then
  echo "Usage: vps-logs <app-name> [--lines N]"
  echo ""
  echo "Available apps:"
  ls "$APPS_DIR" 2>/dev/null | sed 's/^/  /' || echo "  No apps deployed"
  exit 1
fi

APP_NAME="$1"
APP_DIR="$APPS_DIR/$APP_NAME"

if [ ! -d "$APP_DIR" ]; then
  echo "Error: App '$APP_NAME' not found."
  echo ""
  echo "Available apps:"
  ls "$APPS_DIR" 2>/dev/null | sed 's/^/  /' || echo "  No apps deployed"
  exit 1
fi

LINES="${2:-}"
if [ "$LINES" = "--lines" ] && [ -n "${3:-}" ]; then
  cd "$APP_DIR" && docker compose logs --tail="$3" -f
else
  cd "$APP_DIR" && docker compose logs --tail=100 -f
fi
CMDEOF
  chmod +x /usr/local/bin/vps-logs
  log "vps-logs installed."
fi

# =============================================================================
# VPS-RESTART
# =============================================================================
section "Installing: vps-restart"

if install_cmd "vps-restart"; then
  cat > /usr/local/bin/vps-restart << 'CMDEOF'
#!/bin/bash
# vps-restart — Restart a deployed app's containers

DEPLOY_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home/ {print $1; exit}' /etc/passwd)
APPS_DIR="/home/$DEPLOY_USER/apps"

if [ -z "$1" ]; then
  echo "Usage: vps-restart <app-name>"
  echo ""
  echo "Available apps:"
  ls "$APPS_DIR" 2>/dev/null | sed 's/^/  /' || echo "  No apps deployed"
  exit 1
fi

APP_NAME="$1"
APP_DIR="$APPS_DIR/$APP_NAME"

if [ ! -d "$APP_DIR" ]; then
  echo "Error: App '$APP_NAME' not found."
  echo ""
  echo "Available apps:"
  ls "$APPS_DIR" 2>/dev/null | sed 's/^/  /' || echo "  No apps deployed"
  exit 1
fi

echo "Restarting $APP_NAME..."
cd "$APP_DIR" && docker compose restart

echo ""
echo "Container status:"
docker compose ps
CMDEOF
  chmod +x /usr/local/bin/vps-restart
  log "vps-restart installed."
fi

# =============================================================================
# VPS-REMOVE-APP
# =============================================================================
section "Installing: vps-remove-app"

if install_cmd "vps-remove-app"; then
  cat > /usr/local/bin/vps-remove-app << 'CMDEOF'
#!/bin/bash
# vps-remove-app — Completely remove a deployed app

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

DEPLOY_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home/ {print $1; exit}' /etc/passwd)
APPS_DIR="/home/$DEPLOY_USER/apps"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR]${NC} Must run as root. Use: sudo vps-remove-app"
  exit 1
fi

# List apps and let user pick
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  REMOVE A DEPLOYED APP${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ ! -d "$APPS_DIR" ] || [ -z "$(ls -A "$APPS_DIR" 2>/dev/null)" ]; then
  echo "No apps deployed."
  exit 0
fi

echo "Deployed apps:"
echo ""
APP_LIST=()
INDEX=1
for app_dir in "$APPS_DIR"/*/; do
  [ ! -d "$app_dir" ] && continue
  APP=$(basename "$app_dir")
  APP_LIST+=("$APP")

  # Check running status
  STATUS="stopped"
  if cd "$app_dir" && docker compose ps 2>/dev/null | grep -q "Up\|running"; then
    STATUS="running"
  fi

  echo "  $INDEX) $APP [$STATUS]"
  ((INDEX++))
done

echo ""
read -p "Select app to remove [1-${#APP_LIST[@]}]: " APP_INDEX

# Validate selection
if ! [[ "$APP_INDEX" =~ ^[0-9]+$ ]] || [ "$APP_INDEX" -lt 1 ] || [ "$APP_INDEX" -gt ${#APP_LIST[@]} ]; then
  echo "Invalid selection."
  exit 1
fi

APP_NAME="${APP_LIST[$((APP_INDEX-1))]}"
APP_DIR="$APPS_DIR/$APP_NAME"

echo ""
echo -e "${YELLOW}[!!]${NC} This will permanently remove '$APP_NAME':"
echo "  - Stop and remove all Docker containers"
echo "  - Delete the app directory: $APP_DIR"
echo "  - Remove the nginx config"

# Check if SSL is configured
DOMAIN=""
if [ -f "$APP_DIR/.deploy-info" ]; then
  DOMAIN=$(grep "^DOMAIN_NAME=" "$APP_DIR/.deploy-info" 2>/dev/null | cut -d= -f2-)
fi
if [ -n "$DOMAIN" ]; then
  echo "  - Optionally revoke the SSL certificate for $DOMAIN"
fi

echo ""
read -p "Type the app name '$APP_NAME' to confirm removal: " CONFIRM

if [ "$CONFIRM" != "$APP_NAME" ]; then
  echo "Names don't match. Aborted."
  exit 0
fi

echo ""

# Step 1: Stop and remove containers
echo ""
echo -e "${YELLOW}[!!]${NC} Docker volumes may contain databases, uploads, or other persistent data."
read -p "Also delete Docker volumes for '$APP_NAME'? (y/n): " DELETE_VOLUMES
echo ""
echo "Stopping Docker containers..."
if [ "$DELETE_VOLUMES" = "y" ]; then
  cd "$APP_DIR" && docker compose down --volumes --remove-orphans 2>/dev/null || true
  echo -e "${GREEN}[OK]${NC} Containers stopped and volumes deleted."
else
  cd "$APP_DIR" && docker compose down --remove-orphans 2>/dev/null || true
  echo -e "${GREEN}[OK]${NC} Containers stopped. Volumes preserved."
fi

# Step 2: Remove nginx config
if [ -f "/etc/nginx/sites-enabled/$APP_NAME" ] || [ -f "/etc/nginx/sites-available/$APP_NAME" ]; then
  rm -f "/etc/nginx/sites-enabled/$APP_NAME"
  rm -f "/etc/nginx/sites-available/$APP_NAME"
  nginx -t > /dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
  echo -e "${GREEN}[OK]${NC} Nginx config removed."
else
  echo -e "${GREEN}[OK]${NC} No nginx config found (already clean)."
fi

# Step 3: Optionally revoke SSL
if [ -n "$DOMAIN" ] && command -v certbot &>/dev/null; then
  if certbot certificates 2>/dev/null | grep -q "$DOMAIN"; then
    read -p "Revoke SSL certificate for $DOMAIN? (y/n): " REVOKE_SSL
    if [ "$REVOKE_SSL" = "y" ]; then
      certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null || true
      echo -e "${GREEN}[OK]${NC} SSL certificate revoked."
    else
      echo -e "${YELLOW}[!!]${NC} SSL certificate kept. Remove manually with: sudo certbot delete --cert-name $DOMAIN"
    fi
  fi
fi

# Step 4: Remove app directory
rm -rf "$APP_DIR"
echo -e "${GREEN}[OK]${NC} App directory removed."

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  '$APP_NAME' has been completely removed.${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
CMDEOF
  chmod +x /usr/local/bin/vps-remove-app
  log "vps-remove-app installed."
fi

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ADMIN TOOLS INSTALLED${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  AVAILABLE COMMANDS"
echo "  ───────────────────────────────────────────────"
echo "  vps-status              Server health dashboard"
echo "  vps-open-port <port>    Open a firewall port"
echo "  vps-close-port <port>   Close a firewall port"
echo "  sudo vps-add-user <name>  Add a system user"
echo "  vps-list-apps           List deployed apps"
echo "  vps-logs <app>          View app logs (live)"
echo "  vps-restart <app>       Restart an app"
echo "  sudo vps-remove-app     Remove a deployed app"
echo ""
echo "  Try it now: vps-status"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
