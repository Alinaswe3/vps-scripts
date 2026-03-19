#!/bin/bash

# =============================================================================
# 04-deploy-app.sh
# Deploy a Dockerized App from a Git Repository
# =============================================================================
#
# PURPOSE:
#   Clone a git repo, configure environment variables, build and start
#   containers with Docker, set up nginx reverse proxy, and optionally
#   configure SSL with certbot. Supports multiple apps on the same VPS.
#
# DEPENDENCIES:
#   - 02-docker-install.sh (Docker must be installed)
#   - 03-nginx-setup.sh (nginx must be installed)
#
# USAGE:
#   sudo bash 04-deploy-app.sh
#
# SAFE TO RE-RUN:
#   Yes — detects existing apps and asks before redeploying.
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
  if [ "$LOCAL_MODE" = true ]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    echo "${ip:-localhost}"
    return
  fi
  ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null) || true
  if [ -z "$ip" ]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  fi
  echo "${ip:-unknown}"
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

[ "$EUID" -ne 0 ] && error "This script must be run as root. Use: sudo bash 04-deploy-app.sh"

# Check dependencies
if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Run 02-docker-install.sh first."
fi

if ! docker compose version &>/dev/null; then
  error "Docker Compose plugin is not installed. Run 02-docker-install.sh first."
fi

if ! command -v nginx &>/dev/null; then
  error "Nginx is not installed. Run 03-nginx-setup.sh first."
fi

# Detect deploy user (first non-root user with a home directory)
DEPLOY_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home/ {print $1; exit}' /etc/passwd)
if [ -z "$DEPLOY_USER" ]; then
  error "No deploy user found. Run 01-vps-harden.sh first to create one."
fi
DEPLOY_HOME="/home/$DEPLOY_USER"
APPS_DIR="$DEPLOY_HOME/apps"
mkdir -p "$APPS_DIR"

# --- Auto-detect VirtualBox for local test mode ---
LOCAL_MODE=false
if [ -f /sys/class/dmi/id/product_name ]; then
  PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
  if echo "$PRODUCT_NAME" | grep -qi "virtualbox"; then
    echo ""
    warn "VirtualBox detected."
    echo "  Local test mode binds nginx and Docker to all interfaces (0.0.0.0)"
    echo "  so you can access the app from your host machine's browser."
    echo ""
    read -p "Run in local test mode? (y/n): " USE_LOCAL
    if [ "$USE_LOCAL" = "y" ]; then
      LOCAL_MODE=true
      log "Local test mode enabled."
      echo ""
      echo "  Make sure VirtualBox port forwarding is configured:"
      echo "    Host 2222 -> Guest 22   (SSH)"
      echo "    Host 8080 -> Guest 80   (HTTP)"
      echo "    Host 8443 -> Guest 443  (HTTPS)"
      echo ""
    fi
  fi
fi

# =============================================================================
# WELCOME BANNER
# =============================================================================
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  APP DEPLOYMENT SCRIPT${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  This script will:"
echo "    1. Clone your app from a git repository"
echo "    2. Configure environment variables"
echo "    3. Build and start Docker containers"
echo "    4. Set up nginx reverse proxy"
echo "    5. Optionally configure SSL (HTTPS)"
echo ""
echo "  Deploy user: $DEPLOY_USER"
echo "  Apps directory: $APPS_DIR"
echo ""

# Show existing apps if any
EXISTING_APPS=$(ls "$APPS_DIR" 2>/dev/null | head -20)
if [ -n "$EXISTING_APPS" ]; then
  echo "  Currently deployed apps:"
  for app in $EXISTING_APPS; do
    echo "    - $app"
  done
  echo ""
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

read -p "Ready to deploy an app? (y/n): " START_CONFIRM
[ "$START_CONFIRM" != "y" ] && echo "Aborted." && exit 0

# =============================================================================
# STEP 1: APP IDENTITY
# =============================================================================
section "Step 1/6 — App Information"

# App name
while true; do
  read -p "App name (lowercase, no spaces, e.g. myapp): " APP_NAME
  [[ "$APP_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] && break
  warn "App name must start with a letter/number and contain only lowercase letters, numbers, hyphens or underscores."
done

APP_DIR="$APPS_DIR/$APP_NAME"

# Check if app already exists
if [ -d "$APP_DIR" ]; then
  warn "An app named '$APP_NAME' is already deployed at $APP_DIR."
  read -p "Remove existing deployment and redeploy? (y/n): " REDEPLOY
  if [ "$REDEPLOY" = "y" ]; then
    echo "Stopping existing containers..."
    cd "$APP_DIR" && docker compose down 2>/dev/null || true
    cd /
    rm -rf "$APP_DIR"
    # Remove old nginx config
    rm -f "/etc/nginx/sites-enabled/$APP_NAME"
    rm -f "/etc/nginx/sites-available/$APP_NAME"
    nginx -t > /dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    log "Previous deployment of '$APP_NAME' removed."
  else
    echo "Aborted."
    exit 0
  fi
fi

mkdir -p "$APP_DIR"

# =============================================================================
# STEP 2: APP SOURCE
# =============================================================================
section "Step 2/6 — App Source"

echo "How would you like to provide your app?"
echo ""
echo "  1) Paste compose file — Paste your docker-compose.yml (use this for registry images)"
echo "  2) Registry image     — Pull a pre-built image from GHCR or Docker Hub"
echo ""

while true; do
  read -p "Select [1-2]: " SOURCE_CHOICE
  case "$SOURCE_CHOICE" in
    1) SOURCE_TYPE="paste";    break ;;
    2) SOURCE_TYPE="registry"; break ;;
    *) warn "Enter 1 or 2." ;;
  esac
done

# --- Initialize defaults ---
REGISTRY_IMAGE=""
REGISTRY_HOST=""
REGISTRY_USER=""

case "$SOURCE_TYPE" in

  # ─────────────────────────────────────────────
  # SOURCE: Paste docker-compose.yml
  # ─────────────────────────────────────────────
  paste)
    echo ""
    echo "Paste your docker-compose.yml contents below."
    echo "When done, press ENTER on a new line, then press CTRL+D."
    echo ""
    echo "--- START PASTE ---"
    COMPOSE_CONTENTS=$(cat)
    echo "--- END PASTE ---"

    [ -z "$COMPOSE_CONTENTS" ] && error "docker-compose.yml contents cannot be empty."

    printf '%s\n' "$COMPOSE_CONTENTS" > "$APP_DIR/docker-compose.yml"
    chmod 600 "$APP_DIR/docker-compose.yml"
    log "docker-compose.yml saved to $APP_DIR"
    cd "$APP_DIR"
    ;;

  # ─────────────────────────────────────────────
  # SOURCE: Registry image (GHCR or Docker Hub)
  # ─────────────────────────────────────────────
  registry)
    echo ""
    echo "Pull a pre-built image from a container registry."
    echo "  Examples:"
    echo "    ghcr.io/alinaswe3/spotrev-marketplace:latest"
    echo "    ghcr.io/alinaswe3/spotrev-marketplace:v1.0.2"
    echo "    nginx:latest"
    echo ""
    read -p "Image (e.g. ghcr.io/user/repo:tag): " REGISTRY_IMAGE
    [ -z "$REGISTRY_IMAGE" ] && error "Image name cannot be empty."

    # Registry authentication
    read -p "Does this registry require authentication? (y/n): " REGISTRY_AUTH
    if [ "$REGISTRY_AUTH" = "y" ]; then
      read -p "Registry hostname (e.g. ghcr.io): " REGISTRY_HOST
      read -p "Registry username: " REGISTRY_USER
      read -s -p "Registry token/password: " REGISTRY_TOKEN; echo ""
      echo "$REGISTRY_TOKEN" | docker login "$REGISTRY_HOST" -u "$REGISTRY_USER" --password-stdin \
        || error "Registry login failed. Check your credentials."
      log "Logged in to $REGISTRY_HOST."
    fi

    # Paste the compose file that references this image
    echo ""
    echo "Now paste your docker-compose.yml (must reference image: $REGISTRY_IMAGE)."
    echo "When done, press ENTER on a new line, then press CTRL+D."
    echo ""
    echo "--- START PASTE ---"
    COMPOSE_CONTENTS=$(cat)
    echo "--- END PASTE ---"
    [ -z "$COMPOSE_CONTENTS" ] && error "docker-compose.yml cannot be empty."
    printf '%s\n' "$COMPOSE_CONTENTS" > "$APP_DIR/docker-compose.yml"
    chmod 600 "$APP_DIR/docker-compose.yml"

    # Pull the image now
    echo "Pulling image from registry..."
    docker pull "$REGISTRY_IMAGE" || error "Failed to pull image. Check the image name and credentials."
    log "Image pulled: $REGISTRY_IMAGE"

    # Save registry metadata for update script
    cat > "$APP_DIR/.registry-info" << REGEOF
REGISTRY_IMAGE=$REGISTRY_IMAGE
REGISTRY_HOST=${REGISTRY_HOST:-}
REGISTRY_USER=${REGISTRY_USER:-}
REGEOF
    chmod 600 "$APP_DIR/.registry-info"
    cd "$APP_DIR"
    ;;
esac

# --- Verify compose file exists ---
if [ ! -f "$APP_DIR/docker-compose.yml" ] && [ ! -f "$APP_DIR/docker-compose.yaml" ]; then
  error "No docker-compose.yml found in $APP_DIR."
fi

DEPLOY_MODE="compose"
log "docker-compose.yml found."

# =============================================================================
# STEP 3: APP PORT
# =============================================================================
section "Step 3/6 — App Port"

echo "What port does your app listen on inside the container?"
echo "  Common ports: 3000 (Node.js), 8000 (Django), 8080 (Spring), 5000 (Flask)"
echo ""

while true; do
  read -p "App port: " APP_PORT
  [[ "$APP_PORT" =~ ^[0-9]+$ ]] && [ "$APP_PORT" -ge 1 ] && [ "$APP_PORT" -le 65535 ] && break
  warn "Enter a valid port number between 1 and 65535."
done

log "App port set to $APP_PORT."

# =============================================================================
# STEP 4: ENVIRONMENT VARIABLES
# =============================================================================
section "Step 4/6 — Environment Variables"

ENV_FILE="$APP_DIR/.env"
HAS_ENV_EXAMPLE=false

# Check for .env.example
if [ -f "$APP_DIR/.env.example" ]; then
  HAS_ENV_EXAMPLE=true
  echo "Found .env.example in your repository."
  echo "We'll walk through each variable so you can set its value."
  echo ""

  # Read .env.example and prompt for each value
> "$ENV_FILE"
  while IFS= read -r line || [ -n "$line" ]; do
    # Pass through empty lines and comments unchanged
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "$line" >> "$ENV_FILE"
      continue
    fi

    # Skip lines without an = sign (not a valid KEY=VALUE)
    if [[ "$line" != *"="* ]]; then
      printf '%s\n' "$line" >> "$ENV_FILE"
      continue
    fi

    # Extract key — everything before the first =
    KEY="${line%%=*}"
    # Trim whitespace from key (safe alternative to xargs)
    KEY="${KEY#"${KEY%%[![:space:]]*}"}"
    KEY="${KEY%"${KEY##*[![:space:]]}"}"

    # Skip if key is empty after trimming
    if [ -z "$KEY" ]; then
      printf '%s\n' "$line" >> "$ENV_FILE"
      continue
    fi

    # Extract default value — everything after the first =
    DEFAULT_VAL="${line#*=}"

    # Strip inline comments — handles all these formats:
    #   KEY=value # comment          →  value
    #   KEY="value" # comment        →  value
    #   KEY='value' # comment        →  value
    #   KEY="value # not a comment"  →  value # not a comment
    #   KEY=http://url/#path         →  http://url/#path
    if [[ "$DEFAULT_VAL" =~ ^\"(.*)\"[[:space:]]*(\#.*)?$ ]]; then
      # Double-quoted value: extract content between quotes
      DISPLAY_VAL="${BASH_REMATCH[1]}"
    elif [[ "$DEFAULT_VAL" =~ ^\'(.*)\'[[:space:]]*(\#.*)?$ ]]; then
      # Single-quoted value: extract content between quotes
      DISPLAY_VAL="${BASH_REMATCH[1]}"
    else
      # Unquoted value: strip trailing " #..." comments
      DISPLAY_VAL="${DEFAULT_VAL%% #*}"
      # Trim trailing whitespace
      DISPLAY_VAL="${DISPLAY_VAL%"${DISPLAY_VAL##*[![:space:]]}"}"
    fi

    if [ -n "$DISPLAY_VAL" ]; then
      read -p "  $KEY [$DISPLAY_VAL]: " USER_VAL < /dev/tty || true
      # Use default if user pressed ENTER
      USER_VAL="${USER_VAL:-$DISPLAY_VAL}"
    else
      read -p "  $KEY: " USER_VAL < /dev/tty || true
    fi

    # Write KEY=VALUE — use printf to avoid expanding $, backticks, etc.
    printf '%s="%s"\n' "$KEY" "$USER_VAL" >> "$ENV_FILE"
  done < "$APP_DIR/.env.example"

  chmod 600 "$ENV_FILE"
  log "Environment variables configured from .env.example."

elif [ -f "$APP_DIR/.env" ]; then
  warn ".env file already exists in the repo (this is unusual — check it doesn't contain secrets in git)."
  read -p "Use the existing .env? (y/n): " USE_EXISTING_ENV
  if [ "$USE_EXISTING_ENV" != "y" ]; then
    rm -f "$ENV_FILE"
  fi
fi

# If no .env exists yet, offer to create one
if [ ! -f "$ENV_FILE" ]; then
  read -p "Does your app need environment variables? (y/n): " NEEDS_ENV
  if [ "$NEEDS_ENV" = "y" ]; then
    echo ""
    echo "Enter environment variables one at a time (KEY=VALUE)."
    echo "Press ENTER on an empty line when done."
    echo ""
    > "$ENV_FILE"
    while true; do
      read -p "  Variable (or ENTER to finish): " ENV_LINE
      [ -z "$ENV_LINE" ] && break
      if [[ "$ENV_LINE" == *"="* ]]; then
        echo "$ENV_LINE" >> "$ENV_FILE"
      else
        warn "Format must be KEY=VALUE. Try again."
      fi
    done

    if [ -s "$ENV_FILE" ]; then
      chmod 600 "$ENV_FILE"
      log "Environment variables saved."
    else
      rm -f "$ENV_FILE"
      log "No environment variables configured."
    fi
  else
    log "No environment variables needed."
  fi
fi

# =============================================================================
# STEP 5: DOMAIN & NGINX
# =============================================================================
section "Step 5/6 — Domain & Nginx"

if [ "$LOCAL_MODE" = true ]; then
  DOMAIN_NAME=""
  SERVER_NAME="localhost"
  log "Local test mode — server_name set to 'localhost'."
else
  read -p "Domain name for this app (e.g. myapp.example.com, or press ENTER for IP only): " DOMAIN_NAME

  if [ -n "$DOMAIN_NAME" ]; then
    SERVER_NAME="$DOMAIN_NAME"
    log "Domain set to $DOMAIN_NAME."
  else
    SERVER_NAME="_"
    log "No domain — app will be accessible via server IP."
  fi
fi

# Write nginx config
echo "Setting up nginx reverse proxy..."

NGINX_ZONE=$(echo "${APP_NAME}" | tr -cs 'a-z0-9' '_' | sed 's/_$//')

# In local mode, listen on all interfaces so host can reach via port forwarding
if [ "$LOCAL_MODE" = true ]; then
  LISTEN_DIRECTIVE="0.0.0.0:80"
else
  LISTEN_DIRECTIVE="80"
fi

cat > "/etc/nginx/sites-available/$APP_NAME" << EOF
# Nginx config for $APP_NAME — generated by 04-deploy-app.sh

limit_req_zone \$binary_remote_addr zone=${NGINX_ZONE}_rl:10m rate=30r/m;

server {
    listen $LISTEN_DIRECTIVE;
    server_name $SERVER_NAME;

    include snippets/security-headers.conf;

    client_max_body_size 20M;

    limit_req zone=${NGINX_ZONE}_rl burst=20 nodelay;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        include snippets/proxy-params.conf;
    }

    # Block sensitive files
    location ~ /\. {
        deny all;
        return 404;
    }

    location ~* \.(env|log|sh|sql|bak|git)$ {
        deny all;
        return 404;
    }
}
EOF

ln -sf "/etc/nginx/sites-available/$APP_NAME" "/etc/nginx/sites-enabled/$APP_NAME"

if nginx -t 2>&1; then
  systemctl reload nginx
  log "Nginx reverse proxy configured."
  log "  $SERVER_NAME -> 127.0.0.1:$APP_PORT"
else
  error "Nginx config test failed. Check the configuration."
fi

# =============================================================================
# STEP 5b: SSL CERTIFICATE (skipped in local test mode)
# =============================================================================
if [ "$LOCAL_MODE" = true ]; then
  SSL_ACTIVE=false
  log "SSL skipped — not available in local test mode."
elif [ -n "$DOMAIN_NAME" ]; then
  echo ""
  SERVER_IP=$(get_server_ip)
  read -p "Set up SSL (HTTPS) for $DOMAIN_NAME? (y/n): " SETUP_SSL

  if [ "$SETUP_SSL" = "y" ]; then
    echo ""
    warn "Before SSL can work, your domain's DNS A record must point to: $SERVER_IP"
    read -p "Is DNS already pointing to this server? (y/n): " DNS_READY

    if [ "$DNS_READY" = "y" ]; then
      read -p "Email for SSL certificate notifications: " SSL_EMAIL
      [ -z "$SSL_EMAIL" ] && error "Email is required for SSL certificates."

      echo ""
      echo "Running SSL verification (dry run)..."
      if certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos --email "$SSL_EMAIL" --dry-run 2>&1; then
        log "Verification passed. Installing SSL certificate..."
        certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos --email "$SSL_EMAIL" --redirect
        log "SSL certificate installed. HTTPS is now active."
        SSL_ACTIVE=true
      else
        warn "SSL verification failed. This usually means DNS is not pointing to this server yet."
        warn "You can set up SSL later by running:"
        warn "  sudo certbot --nginx -d $DOMAIN_NAME"
        SSL_ACTIVE=false
      fi
    else
      warn "SSL skipped. When DNS is ready, run:"
      warn "  sudo certbot --nginx -d $DOMAIN_NAME"
      SSL_ACTIVE=false
    fi
  else
    SSL_ACTIVE=false
  fi
else
  SSL_ACTIVE=false
fi

# =============================================================================
# STEP 6: START APP
# =============================================================================
section "Step 6/6 — Starting App"

cd "$APP_DIR"

echo "Starting containers..."
if [ "$SOURCE_TYPE" = "registry" ]; then
  # Image already pulled — just start
  docker compose up -d --remove-orphans 2>&1
else
  # Paste/compose — pull any referenced images then start
  docker compose pull 2>&1 || true
  docker compose up -d --remove-orphans 2>&1
fi

# Wait and check health
echo ""
echo "Waiting for app to start..."
sleep 5

APP_HEALTHY=false
for i in {1..12}; do
  if docker compose ps 2>/dev/null | grep -q "Up\|running"; then
    APP_HEALTHY=true
    break
  fi
  echo "  Checking... (attempt $i/12)"
  sleep 5
done

if [ "$APP_HEALTHY" = true ]; then
  log "App is running."
else
  warn "App may not have started correctly. Check logs with:"
  warn "  cd $APP_DIR && docker compose logs"
fi

# =============================================================================
# SAVE DEPLOYMENT METADATA
# =============================================================================

cat > "$APP_DIR/.deploy-info" << EOF
# Deployment metadata — generated by 04-deploy-app.sh
# Used by 05-update-app.sh for updates and rollbacks

APP_NAME=$APP_NAME
APP_DIR=$APP_DIR
APP_PORT=$APP_PORT
SOURCE_TYPE=$SOURCE_TYPE
REGISTRY_IMAGE=${REGISTRY_IMAGE:-}
DEPLOY_MODE=$DEPLOY_MODE
DOMAIN_NAME=${DOMAIN_NAME:-}
DEPLOY_USER=$DEPLOY_USER
SSL_ACTIVE=${SSL_ACTIVE:-false}
LOCAL_MODE=$LOCAL_MODE
DEPLOYED_AT=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
EOF

chmod 600 "$APP_DIR/.deploy-info"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR"
log "Deployment metadata saved."

# =============================================================================
# DONE
# =============================================================================
SERVER_IP=$(get_server_ip)

if [ "$LOCAL_MODE" = true ]; then
  APP_URL="http://localhost:8080 (via VirtualBox port forwarding)"
elif [ "${SSL_ACTIVE:-false}" = true ]; then
  APP_URL="https://$DOMAIN_NAME"
elif [ -n "${DOMAIN_NAME:-}" ]; then
  APP_URL="http://$DOMAIN_NAME"
else
  APP_URL="http://$SERVER_IP"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  DEPLOYMENT COMPLETE${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  App name      : $APP_NAME"
echo "  App URL       : $APP_URL"
echo "  App directory : $APP_DIR"
echo "  App port      : $APP_PORT"
echo "  Source        : $SOURCE_TYPE"
[ "$SOURCE_TYPE" = "registry" ] && echo "  Image         : $REGISTRY_IMAGE"
echo "  SSL           : ${SSL_ACTIVE:-false}"
echo ""
echo "  WHAT WAS CONFIGURED"
echo "  ───────────────────────────────────────────────"
if [ "$SOURCE_TYPE" = "paste" ]; then
echo "  [OK] docker-compose.yml saved from pasted content"
elif [ "$SOURCE_TYPE" = "registry" ]; then
echo "  [OK] Image pulled from registry: $REGISTRY_IMAGE"
fi
if [ -f "$APP_DIR/.env" ]; then
echo "  [OK] Environment variables configured"
fi
echo "  [OK] Docker containers built and started"
echo "  [OK] Nginx reverse proxy active"
if [ "${SSL_ACTIVE:-false}" = true ]; then
echo "  [OK] SSL certificate installed (auto-renews)"
fi
echo ""
echo "  USEFUL COMMANDS"
echo "  ───────────────────────────────────────────────"
echo "  Update app     : sudo bash 05-update-app.sh"
echo "  View logs      : cd $APP_DIR && docker compose logs -f"
echo "  Stop app       : cd $APP_DIR && docker compose down"
echo "  Start app      : cd $APP_DIR && docker compose up -d"
echo "  Restart app    : cd $APP_DIR && docker compose restart"
echo ""
echo "  NEXT STEPS"
echo "  ───────────────────────────────────────────────"
echo "  1. Visit $APP_URL to verify your app is running"
echo "  2. To deploy another app, run this script again"
echo "  3. To update this app later, run: sudo bash 05-update-app.sh"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"