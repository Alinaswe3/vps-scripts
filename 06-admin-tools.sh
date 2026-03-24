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
#   vps-cleanup       — Free disk space (Docker cache, unused images, old backups, logs, APT)
#   vps-remove-app    — Completely remove a deployed app
#   vps-cleanup       — Free disk space (Docker junk, old backups, logs, caches)
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
echo "    vps-restart      — Restart an app"
echo "    vps-nginx-config — Set up nginx for an app"
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
# VPS-NGINX-CONFIG
# =============================================================================
section "Installing: vps-nginx-config"

if install_cmd "vps-nginx-config"; then
  cat > /usr/local/bin/vps-nginx-config << 'CMDEOF'
#!/bin/bash
# vps-nginx-config — Create or reset nginx reverse proxy for a deployed app

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR]${NC} Must run as root. Use: sudo vps-nginx-config"
  exit 1
fi

if ! command -v nginx &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Nginx is not installed. Run 03-nginx-setup.sh first."
  exit 1
fi

DEPLOY_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home/ {print $1; exit}' /etc/passwd)
APPS_DIR="/home/$DEPLOY_USER/apps"

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  NGINX CONFIG FOR APP${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# --- List deployed apps ---
if [ ! -d "$APPS_DIR" ] || [ -z "$(ls -A "$APPS_DIR" 2>/dev/null)" ]; then
  echo "No apps deployed. Deploy one first with: sudo bash 04-deploy-app.sh"
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

  STATUS="stopped"
  if cd "$app_dir" && docker compose ps 2>/dev/null | grep -q "Up\|running"; then
    STATUS="running"
  fi

  HAS_NGINX="no nginx"
  [ -f "/etc/nginx/sites-available/$APP" ] && HAS_NGINX="nginx configured"

  echo "  $INDEX) $APP [$STATUS] [$HAS_NGINX]"
  ((INDEX++))
done

echo ""
read -p "Select app [1-${#APP_LIST[@]}]: " APP_INDEX

if ! [[ "$APP_INDEX" =~ ^[0-9]+$ ]] || [ "$APP_INDEX" -lt 1 ] || [ "$APP_INDEX" -gt ${#APP_LIST[@]} ]; then
  echo "Invalid selection."
  exit 1
fi

APP_NAME="${APP_LIST[$((APP_INDEX-1))]}"
APP_DIR="$APPS_DIR/$APP_NAME"

# --- Check for existing nginx config ---
if [ -f "/etc/nginx/sites-available/$APP_NAME" ]; then
  echo ""
  echo -e "${YELLOW}[!!]${NC} Nginx config already exists for '$APP_NAME':"
  echo ""
  cat "/etc/nginx/sites-available/$APP_NAME" | sed 's/^/    /'
  echo ""
  read -p "Reset this config? (y/n): " RESET_CONF
  if [ "$RESET_CONF" != "y" ]; then
    echo "Keeping existing config."
    exit 0
  fi
fi

# --- Detect local mode from .deploy-info ---
LOCAL_MODE="false"
if [ -f "$APP_DIR/.deploy-info" ]; then
  LOCAL_MODE=$(grep "^LOCAL_MODE=" "$APP_DIR/.deploy-info" 2>/dev/null | cut -d'"' -f2)
  LOCAL_MODE="${LOCAL_MODE:-false}"
fi

# --- Auto-detect app port from compose file ---
COMPOSE_FILE=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
  [ -f "$APP_DIR/$f" ] && COMPOSE_FILE="$APP_DIR/$f" && break
done

# Also check COMPOSE_DIR from deploy-info
if [ -z "$COMPOSE_FILE" ] && [ -f "$APP_DIR/.deploy-info" ]; then
  COMP_DIR=$(grep "^COMPOSE_DIR=" "$APP_DIR/.deploy-info" 2>/dev/null | cut -d'"' -f2)
  COMP_NAME=$(grep "^COMPOSE_FILENAME=" "$APP_DIR/.deploy-info" 2>/dev/null | cut -d'"' -f2)
  [ -n "$COMP_DIR" ] && [ -n "$COMP_NAME" ] && [ -f "$COMP_DIR/$COMP_NAME" ] && COMPOSE_FILE="$COMP_DIR/$COMP_NAME"
fi

DETECTED_PORT=""
if [ -n "$COMPOSE_FILE" ]; then
  # Try to extract host port from ports mapping (e.g. "127.0.0.1:3000:3000" or "3000:3000")
  DETECTED_PORT=$(grep -A5 "ports:" "$COMPOSE_FILE" 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:([0-9]+):[0-9]+' \
    | head -1 | cut -d: -f2)
  [ -z "$DETECTED_PORT" ] && DETECTED_PORT=$(grep -A5 "ports:" "$COMPOSE_FILE" 2>/dev/null \
    | grep -oE '"?([0-9]+):[0-9]+"?' \
    | head -1 | tr -d '"' | cut -d: -f1)
fi

echo ""
if [ -n "$DETECTED_PORT" ]; then
  read -p "App port (detected: $DETECTED_PORT, press ENTER to use): " APP_PORT
  APP_PORT="${APP_PORT:-$DETECTED_PORT}"
else
  echo "Could not auto-detect the app port."
  read -p "What port does your app listen on? (e.g. 3000): " APP_PORT
fi

if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]] || [ "$APP_PORT" -lt 1 ] || [ "$APP_PORT" -gt 65535 ]; then
  echo "Invalid port."
  exit 1
fi

# --- Local mode: skip routing choice, use localhost ---
if [ "$LOCAL_MODE" = "true" ]; then
  echo ""
  echo -e "${YELLOW}[!!]${NC} VirtualBox local mode — using localhost routing."
  ROUTE_TYPE="local"
  LISTEN_DIRECTIVE="0.0.0.0:80"
  SERVER_NAME="localhost"
else
  # --- Choose routing type ---
  echo ""
  echo "How should this app be accessed?"
  echo ""
  echo "  1) Domain    — app1.example.com (recommended for production)"
  echo "  2) Port      — http://SERVER_IP:PORT (simpler, no domain needed)"
  echo ""

  while true; do
    read -p "Select [1-2]: " ROUTE_CHOICE
    case "$ROUTE_CHOICE" in
      1) ROUTE_TYPE="domain"; break ;;
      2) ROUTE_TYPE="port"; break ;;
      *) echo "Enter 1 or 2." ;;
    esac
  done

  if [ "$ROUTE_TYPE" = "domain" ]; then
    read -p "Domain name (e.g. myapp.example.com): " DOMAIN_NAME
    [ -z "$DOMAIN_NAME" ] && echo "Domain cannot be empty." && exit 1
    LISTEN_DIRECTIVE="80"
    SERVER_NAME="$DOMAIN_NAME"

  else
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
    echo ""
    echo "Choose a public port for nginx to listen on."
    echo "  This is the port users visit in their browser (e.g. 8080)."
    echo "  It must be different from ports used by other apps."
    echo ""
    read -p "Public port: " PUBLIC_PORT
    if ! [[ "$PUBLIC_PORT" =~ ^[0-9]+$ ]] || [ "$PUBLIC_PORT" -lt 1 ] || [ "$PUBLIC_PORT" -gt 65535 ]; then
      echo "Invalid port."
      exit 1
    fi
    LISTEN_DIRECTIVE="$PUBLIC_PORT"
    SERVER_NAME="_"
  fi
fi

# --- Generate nginx config ---
echo ""
echo "Writing nginx config..."

# Remove old config first to avoid duplicate zone conflicts
rm -f "/etc/nginx/sites-enabled/$APP_NAME"
rm -f "/etc/nginx/sites-available/$APP_NAME"

NGINX_ZONE=$(echo "${APP_NAME}" | tr -cs 'a-z0-9' '_' | sed 's/_$//')

cat > "/etc/nginx/sites-available/$APP_NAME" << NGINXEOF
# Nginx config for $APP_NAME — generated by vps-nginx-config

limit_req_zone \$binary_remote_addr zone=${NGINX_ZONE}_rl:10m rate=10r/s;

server {
    listen $LISTEN_DIRECTIVE;
    server_name $SERVER_NAME;

    include snippets/security-headers.conf;

    client_max_body_size 50M;

    # Static assets — no rate limit, cached
    location ~* \.(js|mjs|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|otf|webp|avif|map|webmanifest|pdf|mp4|webm|ogg|mp3|wav|zip)\$ {
        proxy_pass http://127.0.0.1:$APP_PORT;
        include snippets/proxy-params.conf;
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # App routes — rate limited
    location / {
        limit_req zone=${NGINX_ZONE}_rl burst=20 nodelay;
        proxy_pass http://127.0.0.1:$APP_PORT;
        include snippets/proxy-params.conf;
    }

    # Block sensitive files
    location ~ /\. {
        deny all;
        return 404;
    }

    location ~* \.(env|log|sh|sql|bak|git)\$ {
        deny all;
        return 404;
    }
}
NGINXEOF

ln -sf "/etc/nginx/sites-available/$APP_NAME" "/etc/nginx/sites-enabled/$APP_NAME"

if nginx -t 2>&1; then
  systemctl reload nginx
  echo -e "${GREEN}[OK]${NC} Nginx config created and loaded."
else
  echo -e "${RED}[ERROR]${NC} Nginx config test failed. Check the config."
  cat "/etc/nginx/sites-available/$APP_NAME"
  exit 1
fi

# --- Open port in UFW if port-based routing ---
if [ "$ROUTE_TYPE" = "port" ] && command -v ufw &>/dev/null; then
  ufw allow "$PUBLIC_PORT/tcp" comment "App: $APP_NAME" > /dev/null 2>&1
  echo -e "${GREEN}[OK]${NC} Port $PUBLIC_PORT opened in firewall."
fi

# --- SSL (domain-based only, skip in local mode) ---
SSL_ACTIVE="false"
if [ "$ROUTE_TYPE" = "domain" ]; then
  echo ""
  read -p "Set up SSL (HTTPS) for $DOMAIN_NAME? (y/n): " SETUP_SSL
  if [ "$SETUP_SSL" = "y" ]; then
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")
    echo ""
    echo -e "${YELLOW}[!!]${NC} Your domain's DNS A record must point to: $SERVER_IP"
    read -p "Is DNS already pointing to this server? (y/n): " DNS_READY

    if [ "$DNS_READY" = "y" ]; then
      read -p "Email for SSL certificate notifications: " SSL_EMAIL
      [ -z "$SSL_EMAIL" ] && echo "Email required." && exit 1

      echo "Running SSL verification (dry run)..."
      if certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos --email "$SSL_EMAIL" --dry-run 2>&1; then
        echo "Installing SSL certificate..."
        certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos --email "$SSL_EMAIL" --redirect
        echo -e "${GREEN}[OK]${NC} SSL installed. HTTPS is active."
        SSL_ACTIVE="true"
      else
        echo -e "${YELLOW}[!!]${NC} SSL verification failed. DNS may not be pointing here yet."
        echo "  Run later: sudo certbot --nginx -d $DOMAIN_NAME"
      fi
    else
      echo "  When DNS is ready, run: sudo certbot --nginx -d $DOMAIN_NAME"
    fi
  fi
fi

# --- Update .deploy-info with nginx details ---
if [ -f "$APP_DIR/.deploy-info" ]; then
  # Remove old nginx entries if present
  sed -i '/^DOMAIN_NAME=/d; /^NGINX_PORT=/d; /^ROUTE_TYPE=/d; /^SSL_ACTIVE=/d' "$APP_DIR/.deploy-info"
  # Append new ones
  {
    echo "ROUTE_TYPE=\"$ROUTE_TYPE\""
    echo "SSL_ACTIVE=\"$SSL_ACTIVE\""
    [ "$ROUTE_TYPE" = "domain" ] && echo "DOMAIN_NAME=\"$DOMAIN_NAME\""
    [ "$ROUTE_TYPE" = "port" ] && echo "NGINX_PORT=\"$PUBLIC_PORT\""
  } >> "$APP_DIR/.deploy-info"
fi

# --- Summary ---
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  NGINX CONFIGURED FOR '$APP_NAME'${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  App port     : $APP_PORT"

if [ "$ROUTE_TYPE" = "domain" ]; then
  if [ "$SSL_ACTIVE" = "true" ]; then
    echo "  URL          : https://$DOMAIN_NAME"
  else
    echo "  URL          : http://$DOMAIN_NAME"
  fi
  echo "  SSL          : $SSL_ACTIVE"
elif [ "$ROUTE_TYPE" = "port" ]; then
  echo "  URL          : http://${SERVER_IP:-your-server-ip}:$PUBLIC_PORT"
elif [ "$ROUTE_TYPE" = "local" ]; then
  echo "  URL          : http://localhost:8080 (via VirtualBox port forwarding)"
fi

echo ""
echo "  To reset     : sudo vps-nginx-config"
echo "  To remove    : sudo rm /etc/nginx/sites-enabled/$APP_NAME && sudo nginx -t && sudo systemctl reload nginx"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
CMDEOF
  chmod +x /usr/local/bin/vps-nginx-config
  log "vps-nginx-config installed."
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
# VPS-CLEANUP
# =============================================================================
section "Installing: vps-cleanup"

if install_cmd "vps-cleanup"; then
  cat > /usr/local/bin/vps-cleanup << 'CMDEOF'
#!/bin/bash
# vps-cleanup — Free disk space on the VPS

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR]${NC} Must run as root. Use: sudo vps-cleanup"
  exit 1
fi

DEPLOY_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home/ {print $1; exit}' /etc/passwd)
APPS_DIR="/home/${DEPLOY_USER}/apps"
TOTAL_FREED=0

bytes_to_human() {
  local bytes=$1
  if [ "$bytes" -ge 1073741824 ]; then
    echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1073741824}") GB"
  elif [ "$bytes" -ge 1048576 ]; then
    echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1048576}") MB"
  elif [ "$bytes" -ge 1024 ]; then
    echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1024}") KB"
  else
    echo "${bytes} B"
  fi
}

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  VPS STORAGE CLEANUP${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# --- Storage Overview ---
echo ""
echo -e "${CYAN}  DISK USAGE OVERVIEW${NC}"
echo -e "${CYAN}  ───────────────────────────────────────────────${NC}"
df -h / | awk 'NR==2 {printf "  Disk: %s used of %s (%s) — %s free\n", $3, $2, $5, $4}'
echo ""

# Docker disk usage summary
if command -v docker &>/dev/null; then
  echo -e "${CYAN}  DOCKER DISK USAGE${NC}"
  echo -e "${CYAN}  ───────────────────────────────────────────────${NC}"
  docker system df 2>/dev/null | while IFS= read -r line; do
    echo "  $line"
  done
  echo ""
fi

# Apps directory size
if [ -d "$APPS_DIR" ]; then
  echo -e "${CYAN}  APPS DIRECTORY${NC}"
  echo -e "${CYAN}  ───────────────────────────────────────────────${NC}"
  du -sh "$APPS_DIR" 2>/dev/null | awk '{printf "  Total: %s  (%s)\n", $1, $2}'
  for app_dir in "$APPS_DIR"/*/; do
    [ ! -d "$app_dir" ] && continue
    app_name=$(basename "$app_dir")
    app_size=$(du -sh "$app_dir" 2>/dev/null | awk '{print $1}')
    echo "    $app_name: $app_size"
  done
  echo ""
fi

echo -e "${YELLOW}  The following cleanup steps will be offered.${NC}"
echo -e "${YELLOW}  Running containers and volumes are NEVER touched.${NC}"
echo ""

# =========================================================================
# STEP 1: Docker build cache
# =========================================================================
if command -v docker &>/dev/null; then
  CACHE_SIZE=$(docker system df 2>/dev/null | awk '/Build Cache/ {print $4}')
  echo -e "${BLUE}[1/7] Docker build cache${NC} (current: ${CACHE_SIZE:-unknown})"
  read -p "  Clean Docker build cache? (y/n): " CLEAN_CACHE
  if [ "$CLEAN_CACHE" = "y" ]; then
    BEFORE=$(df / --output=avail -B1 | tail -1 | tr -d ' ')
    docker builder prune -f 2>/dev/null || true
    AFTER=$(df / --output=avail -B1 | tail -1 | tr -d ' ')
    FREED=$((AFTER - BEFORE))
    [ "$FREED" -lt 0 ] && FREED=0
    TOTAL_FREED=$((TOTAL_FREED + FREED))
    echo -e "  ${GREEN}[OK]${NC} Build cache cleaned. Freed $(bytes_to_human $FREED)"
  else
    echo "  Skipped."
  fi
  echo ""

  # =========================================================================
  # STEP 2: Dangling and unused images (not used by running containers)
  # =========================================================================
  DANGLING_COUNT=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
  # Unused = images not referenced by any container (running or stopped)
  UNUSED_COUNT=$(docker images --format '{{.ID}}' 2>/dev/null | while read img; do
    docker ps -a --filter "ancestor=$img" -q 2>/dev/null | grep -q . || echo "$img"
  done | wc -l)

  echo -e "${BLUE}[2/7] Unused Docker images${NC} (dangling: $DANGLING_COUNT, unused: $UNUSED_COUNT)"
  if [ "$DANGLING_COUNT" -gt 0 ] || [ "$UNUSED_COUNT" -gt 0 ]; then
    read -p "  Remove dangling images? (y/n): " CLEAN_DANGLING
    if [ "$CLEAN_DANGLING" = "y" ]; then
      BEFORE=$(df / --output=avail -B1 | tail -1 | tr -d ' ')
      docker image prune -f 2>/dev/null || true
      AFTER=$(df / --output=avail -B1 | tail -1 | tr -d ' ')
      FREED=$((AFTER - BEFORE))
      [ "$FREED" -lt 0 ] && FREED=0
      TOTAL_FREED=$((TOTAL_FREED + FREED))
      echo -e "  ${GREEN}[OK]${NC} Dangling images removed. Freed $(bytes_to_human $FREED)"
    else
      echo "  Skipped."
    fi

    if [ "$UNUSED_COUNT" -gt 0 ]; then
      echo ""
      echo -e "  ${YELLOW}[!!]${NC} There are also $UNUSED_COUNT images not used by any container."
      echo "  These may include old versions of your app images."
      read -p "  Remove ALL unused images (keeps images used by running containers)? (y/n): " CLEAN_UNUSED
      if [ "$CLEAN_UNUSED" = "y" ]; then
        BEFORE=$(df / --output=avail -B1 | tail -1 | tr -d ' ')
        docker image prune -a -f --filter "until=24h" 2>/dev/null || true
        AFTER=$(df / --output=avail -B1 | tail -1 | tr -d ' ')
        FREED=$((AFTER - BEFORE))
        [ "$FREED" -lt 0 ] && FREED=0
        TOTAL_FREED=$((TOTAL_FREED + FREED))
        echo -e "  ${GREEN}[OK]${NC} Unused images removed. Freed $(bytes_to_human $FREED)"
      else
        echo "  Skipped."
      fi
    fi
  else
    echo "  Nothing to clean."
  fi
  echo ""

  # =========================================================================
  # STEP 3: Stopped containers
  # =========================================================================
  STOPPED_COUNT=$(docker ps -a --filter "status=exited" --filter "status=dead" --filter "status=created" -q 2>/dev/null | wc -l)
  echo -e "${BLUE}[3/7] Stopped containers${NC} (found: $STOPPED_COUNT)"
  if [ "$STOPPED_COUNT" -gt 0 ]; then
    echo "  Stopped containers:"
    docker ps -a --filter "status=exited" --filter "status=dead" --filter "status=created" --format "    {{.Names}} ({{.Image}}) — stopped {{.Status}}" 2>/dev/null
    read -p "  Remove all stopped containers? (y/n): " CLEAN_STOPPED
    if [ "$CLEAN_STOPPED" = "y" ]; then
      BEFORE=$(df / --output=avail -B1 | tail -1 | tr -d ' ')
      docker container prune -f 2>/dev/null || true
      AFTER=$(df / --output=avail -B1 | tail -1 | tr -d ' ')
      FREED=$((AFTER - BEFORE))
      [ "$FREED" -lt 0 ] && FREED=0
      TOTAL_FREED=$((TOTAL_FREED + FREED))
      echo -e "  ${GREEN}[OK]${NC} Stopped containers removed. Freed $(bytes_to_human $FREED)"
    else
      echo "  Skipped."
    fi
  else
    echo "  Nothing to clean."
  fi
  echo ""

  # =========================================================================
  # STEP 4: Unused Docker networks
  # =========================================================================
  UNUSED_NETS=$(docker network ls --filter "type=custom" -q 2>/dev/null | while read net; do
    CONNECTED=$(docker network inspect "$net" --format '{{len .Containers}}' 2>/dev/null)
    [ "$CONNECTED" = "0" ] && echo "$net"
  done | wc -l)
  echo -e "${BLUE}[4/7] Unused Docker networks${NC} (found: $UNUSED_NETS)"
  if [ "$UNUSED_NETS" -gt 0 ]; then
    read -p "  Remove unused networks? (y/n): " CLEAN_NETS
    if [ "$CLEAN_NETS" = "y" ]; then
      docker network prune -f 2>/dev/null || true
      echo -e "  ${GREEN}[OK]${NC} Unused networks removed."
    else
      echo "  Skipped."
    fi
  else
    echo "  Nothing to clean."
  fi
  echo ""
fi

# =========================================================================
# STEP 5: Old app backups (keep last 5 per app)
# =========================================================================
echo -e "${BLUE}[5/7] Old app backups${NC} (keeping last 5 per app)"
BACKUP_FOUND=false
if [ -d "$APPS_DIR" ]; then
  for app_dir in "$APPS_DIR"/*/; do
    [ ! -d "$app_dir" ] && continue
    BACKUP_DIR="${app_dir}.backups"
    [ ! -d "$BACKUP_DIR" ] && continue

    app_name=$(basename "$app_dir")
    # Count backup directories (sorted oldest first)
    BACKUP_LIST=($(ls -dt "$BACKUP_DIR"/*/ 2>/dev/null))
    BACKUP_COUNT=${#BACKUP_LIST[@]}

    if [ "$BACKUP_COUNT" -gt 5 ]; then
      BACKUP_FOUND=true
      OLD_COUNT=$((BACKUP_COUNT - 5))
      OLD_SIZE=$(du -shc "${BACKUP_LIST[@]:5}" 2>/dev/null | tail -1 | awk '{print $1}')
      echo "  $app_name: $BACKUP_COUNT backups found, $OLD_COUNT older than last 5 ($OLD_SIZE)"
      read -p "  Delete $OLD_COUNT old backups for '$app_name'? (y/n): " CLEAN_BACKUPS
      if [ "$CLEAN_BACKUPS" = "y" ]; then
        BEFORE=$(df / --output=avail -B1 | tail -1 | tr -d ' ')
        for old_backup in "${BACKUP_LIST[@]:5}"; do
          rm -rf "$old_backup"
        done
        AFTER=$(df / --output=avail -B1 | tail -1 | tr -d ' ')
        FREED=$((AFTER - BEFORE))
        [ "$FREED" -lt 0 ] && FREED=0
        TOTAL_FREED=$((TOTAL_FREED + FREED))
        echo -e "  ${GREEN}[OK]${NC} Removed $OLD_COUNT old backups. Freed $(bytes_to_human $FREED)"
      else
        echo "  Skipped."
      fi
    fi
  done
fi
if [ "$BACKUP_FOUND" = false ]; then
  echo "  Nothing to clean (all apps have 5 or fewer backups)."
fi
echo ""

# =========================================================================
# STEP 6: System journal logs (older than 7 days)
# =========================================================================
if command -v journalctl &>/dev/null; then
  JOURNAL_SIZE=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+\s*[KMGT]' || echo "unknown")
  echo -e "${BLUE}[6/7] System journal logs${NC} (current: ${JOURNAL_SIZE:-unknown})"
  read -p "  Trim journal logs older than 7 days? (y/n): " CLEAN_JOURNAL
  if [ "$CLEAN_JOURNAL" = "y" ]; then
    BEFORE=$(df / --output=avail -B1 | tail -1 | tr -d ' ')
    journalctl --vacuum-time=7d > /dev/null 2>&1 || true
    AFTER=$(df / --output=avail -B1 | tail -1 | tr -d ' ')
    FREED=$((AFTER - BEFORE))
    [ "$FREED" -lt 0 ] && FREED=0
    TOTAL_FREED=$((TOTAL_FREED + FREED))
    echo -e "  ${GREEN}[OK]${NC} Journal trimmed. Freed $(bytes_to_human $FREED)"
  else
    echo "  Skipped."
  fi
  echo ""
fi

# =========================================================================
# STEP 7: APT package cache and old kernels
# =========================================================================
if command -v apt &>/dev/null; then
  APT_CACHE_SIZE=$(du -sh /var/cache/apt/archives/ 2>/dev/null | awk '{print $1}')
  echo -e "${BLUE}[7/7] APT cache & old packages${NC} (cache: ${APT_CACHE_SIZE:-unknown})"
  read -p "  Clean APT cache and remove old packages? (y/n): " CLEAN_APT
  if [ "$CLEAN_APT" = "y" ]; then
    BEFORE=$(df / --output=avail -B1 | tail -1 | tr -d ' ')
    apt-get clean -y > /dev/null 2>&1 || true
    apt-get autoremove -y > /dev/null 2>&1 || true
    AFTER=$(df / --output=avail -B1 | tail -1 | tr -d ' ')
    FREED=$((AFTER - BEFORE))
    [ "$FREED" -lt 0 ] && FREED=0
    TOTAL_FREED=$((TOTAL_FREED + FREED))
    echo -e "  ${GREEN}[OK]${NC} APT cache cleaned. Freed $(bytes_to_human $FREED)"
  else
    echo "  Skipped."
  fi
  echo ""
fi

# =========================================================================
# SUMMARY
# =========================================================================
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  CLEANUP COMPLETE${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Total freed: $(bytes_to_human $TOTAL_FREED)"
echo ""
df -h / | awk 'NR==2 {printf "  Disk now: %s used of %s (%s) — %s free\n", $3, $2, $5, $4}'
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
CMDEOF
  chmod +x /usr/local/bin/vps-cleanup
  log "vps-cleanup installed."
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
echo "  sudo vps-nginx-config   Set up/reset nginx for an app"
echo "  sudo vps-remove-app     Remove a deployed app"
echo "  sudo vps-cleanup        Free disk space"
echo ""
echo "  Try it now: vps-status"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
