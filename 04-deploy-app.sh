#!/bin/bash

# =============================================================================
# 04-deploy-app.sh
# Generic Docker App Deployment Script
# -----------------------------------------------------------------------------
# Deploys any Dockerized app to a VPS that already has Docker installed.
# Works with: GitHub repos, Docker Hub images, GitHub Container Registry.
# Supports: docker-compose.yml or single containers.
# Supports: multiple apps on the same VPS, each with their own nginx + SSL.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${GREEN}[✔]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✘]${NC} $1"; exit 1; }
info()    { echo -e "${CYAN}[i]${NC} $1"; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $1${NC}\n${BLUE}══════════════════════════════════════${NC}\n"; }

# --- Must NOT run as root ---
[ "$EUID" -eq 0 ] && error "Do not run as root. Run as your deploy user."

# --- Docker must be installed ---
command -v docker &>/dev/null || error "Docker is not installed. Run 01-vps-setup.sh first."
docker compose version &>/dev/null || error "Docker Compose plugin not found. Run 01-vps-setup.sh first."

DEPLOY_USER=$(whoami)
DEPLOY_HOME="/home/$DEPLOY_USER"
APPS_DIR="$DEPLOY_HOME/apps"
mkdir -p "$APPS_DIR"

# =============================================================================
# COLLECT: APP IDENTITY
# =============================================================================
section "Generic App Deployment — App Info"

echo "This script deploys any Dockerized app to this VPS."
echo ""

# App name (used for directory, nginx config, systemd service)
while true; do
  read -p "App name (lowercase, no spaces, e.g. myapp): " APP_NAME
  [[ "$APP_NAME" =~ ^[a-z0-9_-]+$ ]] && break
  warn "App name must be lowercase letters, numbers, hyphens or underscores only."
done

APP_DIR="$APPS_DIR/$APP_NAME"

# Check if app already exists
if [ -d "$APP_DIR" ]; then
  warn "An app named '$APP_NAME' already exists at $APP_DIR."
  read -p "Overwrite it? (yes/no): " OVERWRITE
  [ "$OVERWRITE" != "yes" ] && error "Aborting. Choose a different app name or remove $APP_DIR manually."
  rm -rf "$APP_DIR"
fi

mkdir -p "$APP_DIR"

# App port (what port the container exposes)
while true; do
  read -p "Port the app runs on inside Docker (e.g. 3000): " APP_PORT
  [[ "$APP_PORT" =~ ^[0-9]+$ ]] && [ "$APP_PORT" -ge 1 ] && [ "$APP_PORT" -le 65535 ] && break
  warn "Enter a valid port number between 1 and 65535."
done

# Check port isn't already in use by another app
if sudo lsof -i ":$APP_PORT" &>/dev/null 2>&1; then
  warn "Port $APP_PORT appears to be in use already."
  read -p "Continue anyway? (yes/no): " PORT_OVERRIDE
  [ "$PORT_OVERRIDE" != "yes" ] && error "Aborting. Choose a different port."
fi

# Domain name
read -p "Domain name for this app (e.g. myapp.com) or press ENTER to use IP: " DOMAIN_NAME

# =============================================================================
# COLLECT: IMAGE SOURCE
# =============================================================================
section "Image Source"

echo "How should Docker get the app image?"
echo ""
echo "  1) GitHub repo    — clone repo and build from Dockerfile"
echo "  2) Docker Hub     — pull a public image (e.g. nginx:latest)"
echo "  3) GHCR           — pull from GitHub Container Registry (ghcr.io)"
echo "  4) docker-compose — I have my own docker-compose.yml to paste"
echo ""
read -p "Choose [1-4]: " IMAGE_SOURCE

case "$IMAGE_SOURCE" in
  1)
    SOURCE_TYPE="github"
    read -p "GitHub username: " GITHUB_USER
    read -p "GitHub repository name: " GITHUB_REPO
    read -p "Branch to deploy (press ENTER for 'main'): " DEPLOY_BRANCH
    DEPLOY_BRANCH=${DEPLOY_BRANCH:-main}
    echo ""
    info "Is this a private repo?"
    read -p "Private repo? (yes/no): " IS_PRIVATE
    if [ "$IS_PRIVATE" = "yes" ]; then
      warn "You need a GitHub Personal Access Token (scope: repo)."
      warn "Generate one at: github.com/settings/tokens"
      read -s -p "GitHub Personal Access Token: " GITHUB_TOKEN; echo ""
    else
      GITHUB_TOKEN=""
    fi
    ;;
  2)
    SOURCE_TYPE="dockerhub"
    read -p "Docker Hub image (e.g. nginx:latest or myuser/myapp:1.0): " DOCKER_IMAGE
    [ -z "$DOCKER_IMAGE" ] && error "Docker image cannot be empty."
    ;;
  3)
    SOURCE_TYPE="ghcr"
    read -p "GHCR image (e.g. ghcr.io/myuser/myapp:latest): " DOCKER_IMAGE
    [ -z "$DOCKER_IMAGE" ] && error "GHCR image cannot be empty."
    warn "You need a GitHub Personal Access Token with read:packages scope."
    read -p "GitHub username: " GITHUB_USER
    read -s -p "GitHub Personal Access Token: " GITHUB_TOKEN; echo ""
    ;;
  4)
    SOURCE_TYPE="compose"
    warn "Paste your docker-compose.yml contents below."
    warn "Press ENTER on a new line, paste everything, then CTRL+D when done:"
    echo "--- START PASTE ---"
    COMPOSE_CONTENTS=$(cat)
    echo "--- END PASTE ---"
    [ -z "$COMPOSE_CONTENTS" ] && error "docker-compose.yml cannot be empty."
    ;;
  *)
    error "Invalid choice. Choose 1, 2, 3, or 4."
    ;;
esac

# =============================================================================
# COLLECT: DEPLOYMENT TYPE (only if not compose)
# =============================================================================
if [ "$SOURCE_TYPE" != "compose" ]; then
  echo ""
  echo "Deployment type:"
  echo "  1) Docker Compose  — app has a docker-compose.yml"
  echo "  2) Single container — just run one Docker container"
  echo ""
  read -p "Choose [1-2]: " DEPLOY_TYPE

  case "$DEPLOY_TYPE" in
    1) DEPLOY_MODE="compose" ;;
    2) DEPLOY_MODE="single" ;;
    *) error "Invalid choice." ;;
  esac
else
  DEPLOY_MODE="compose"
fi

# =============================================================================
# COLLECT: ENVIRONMENT VARIABLES
# =============================================================================
section "Environment Variables"

read -p "Does this app need a .env file? (yes/no): " NEEDS_ENV

if [ "$NEEDS_ENV" = "yes" ]; then
  warn "Paste your .env file contents below."
  warn "Press ENTER on a new line, paste everything, then CTRL+D when done:"
  echo "--- START PASTE ---"
  ENV_CONTENTS=$(cat)
  echo "--- END PASTE ---"
  [ -z "$ENV_CONTENTS" ] && warn "Empty .env provided — skipping."
fi

# =============================================================================
# COLLECT: SINGLE CONTAINER OPTIONS
# =============================================================================
if [ "$DEPLOY_MODE" = "single" ]; then
  section "Single Container Options"

  read -p "Container name (press ENTER for '$APP_NAME'): " CONTAINER_NAME
  CONTAINER_NAME=${CONTAINER_NAME:-$APP_NAME}

  read -p "Any extra docker run flags? (press ENTER to skip, e.g. -e NODE_ENV=production): " EXTRA_FLAGS
fi

# =============================================================================
# CONFIRM
# =============================================================================
section "Deployment Summary — Please Confirm"

echo "  App name      : $APP_NAME"
echo "  App directory : $APP_DIR"
echo "  App port      : $APP_PORT"
echo "  Source type   : $SOURCE_TYPE"
echo "  Deploy mode   : $DEPLOY_MODE"
if [ -n "${DOMAIN_NAME:-}" ]; then
echo "  Domain        : $DOMAIN_NAME"
else
echo "  Domain        : None (IP only)"
fi
echo ""
read -p "Proceed with deployment? (yes/no): " CONFIRM
[ "$CONFIRM" != "yes" ] && echo "Aborted." && exit 0

# =============================================================================
# GET THE CODE / IMAGE
# =============================================================================
section "Getting App Source"

case "$SOURCE_TYPE" in
  github)
    if [ "$IS_PRIVATE" = "yes" ]; then
      git clone "https://$GITHUB_TOKEN@github.com/$GITHUB_USER/$GITHUB_REPO.git" "$APP_DIR"
    else
      git clone "https://github.com/$GITHUB_USER/$GITHUB_REPO.git" "$APP_DIR"
    fi
    cd "$APP_DIR"
    git checkout "$DEPLOY_BRANCH"
    log "Repository cloned. Branch: $DEPLOY_BRANCH"
    ;;

  dockerhub)
    docker pull "$DOCKER_IMAGE"
    log "Image pulled from Docker Hub: $DOCKER_IMAGE"
    cd "$APP_DIR"
    ;;

  ghcr)
    echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin
    docker pull "$DOCKER_IMAGE"
    log "Image pulled from GHCR: $DOCKER_IMAGE"
    cd "$APP_DIR"
    ;;

  compose)
    cd "$APP_DIR"
    echo "$COMPOSE_CONTENTS" > "$APP_DIR/docker-compose.yml"
    chmod 600 "$APP_DIR/docker-compose.yml"
    log "docker-compose.yml written to $APP_DIR"
    ;;
esac

# =============================================================================
# WRITE .env FILE
# =============================================================================
if [ "${NEEDS_ENV:-no}" = "yes" ] && [ -n "${ENV_CONTENTS:-}" ]; then
  echo "$ENV_CONTENTS" > "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env"
  log ".env file written and secured (chmod 600)."
fi

# =============================================================================
# GENERATE docker-compose.yml FOR SINGLE CONTAINERS
# =============================================================================
if [ "$DEPLOY_MODE" = "single" ] && [ "$SOURCE_TYPE" != "compose" ]; then
  section "Generating docker-compose.yml"

  ENV_SECTION=""
  if [ "${NEEDS_ENV:-no}" = "yes" ] && [ -n "${ENV_CONTENTS:-}" ]; then
    ENV_SECTION="    env_file:\n      - .env"
  fi

  IMAGE_REF=""
  case "$SOURCE_TYPE" in
    github)   IMAGE_REF="build: ." ;;
    dockerhub|ghcr) IMAGE_REF="image: $DOCKER_IMAGE" ;;
  esac

  cat > "$APP_DIR/docker-compose.yml" << EOF
services:
  $APP_NAME:
    $IMAGE_REF
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    ports:
      - "127.0.0.1:$APP_PORT:$APP_PORT"
$([ -n "$ENV_SECTION" ] && echo -e "$ENV_SECTION")
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
  log "docker-compose.yml generated."
fi

# =============================================================================
# NGINX CONFIGURATION
# =============================================================================
section "Configuring nginx"

if [ -n "${DOMAIN_NAME:-}" ]; then
  SERVER_NAME="$DOMAIN_NAME www.$DOMAIN_NAME"
else
  SERVER_NAME="_"
  warn "No domain provided. App will be served on the server IP."
fi

# Check if snippets exist from 01-vps-setup.sh, create fallback if not
if [ ! -f /etc/nginx/snippets/security-headers.conf ]; then
  sudo mkdir -p /etc/nginx/snippets
  sudo tee /etc/nginx/snippets/security-headers.conf > /dev/null << EOF
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
EOF
fi

if [ ! -f /etc/nginx/snippets/proxy-params.conf ]; then
  sudo tee /etc/nginx/snippets/proxy-params.conf > /dev/null << EOF
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
fi

# Sanitize app name for nginx zone (replace non-alphanumeric with _)
NGINX_ZONE_NAME=$(echo "${APP_NAME}" | tr -cs 'a-z0-9' '_' | head -c 32)

sudo tee /etc/nginx/sites-available/$APP_NAME > /dev/null << EOF
# Rate limiting zone for $APP_NAME
limit_req_zone \$binary_remote_addr zone=${NGINX_ZONE_NAME}_rl:10m rate=30r/m;

server {
    listen 80;
    server_name $SERVER_NAME;

    server_tokens off;

    include snippets/security-headers.conf;

    client_max_body_size 20M;

    # Rate limiting
    limit_req zone=${NGINX_ZONE_NAME}_rl burst=20 nodelay;

    location / {
        proxy_pass http://localhost:$APP_PORT;
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

sudo ln -sf /etc/nginx/sites-available/$APP_NAME /etc/nginx/sites-enabled/$APP_NAME
sudo nginx -t && sudo systemctl reload nginx
log "nginx configured for $APP_NAME on port $APP_PORT."

# =============================================================================
# SSL CERTIFICATE
# =============================================================================
if [ -n "${DOMAIN_NAME:-}" ]; then
  section "Setting Up SSL for $DOMAIN_NAME"

  PUBLIC_IP=$(curl -s ifconfig.me)
  warn "Your domain DNS A record must point to: $PUBLIC_IP"
  echo ""
  read -p "Has DNS been pointed to this server? (yes/no): " DNS_READY

  if [ "$DNS_READY" = "yes" ]; then
    read -p "Email for SSL certificate alerts: " SSL_EMAIL

    # Dry run first to catch DNS/config issues before making changes
    warn "Running SSL dry-run to verify DNS is correct..."
    if sudo certbot --nginx \
      -d "$DOMAIN_NAME" \
      -d "www.$DOMAIN_NAME" \
      --non-interactive \
      --agree-tos \
      --email "$SSL_EMAIL" \
      --dry-run 2>&1; then
      log "Dry-run passed. Installing certificate..."
      sudo certbot --nginx \
        -d "$DOMAIN_NAME" \
        -d "www.$DOMAIN_NAME" \
        --non-interactive \
        --agree-tos \
        --email "$SSL_EMAIL" \
        --redirect
      log "SSL certificate installed."

      # Add HSTS header now that SSL is confirmed working
      sudo tee /etc/nginx/snippets/hsts.conf > /dev/null << EOF
# HSTS — tells browsers to always use HTTPS for this domain
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF
      # Inject HSTS include into this app's nginx config
      sudo sed -i "/include snippets\/security-headers.conf;/a\\    include snippets/hsts.conf;" \
        /etc/nginx/sites-available/$APP_NAME
      sudo nginx -t && sudo systemctl reload nginx
      log "HSTS header added. Browsers will now enforce HTTPS."
    else
      error "SSL dry-run failed. Check that $DOMAIN_NAME DNS A record points to $(curl -s ifconfig.me) and try again."
    fi
  else
    warn "Skipping SSL. Run when DNS is ready:"
    warn "sudo certbot --nginx -d $DOMAIN_NAME -d www.$DOMAIN_NAME"
    warn "Then add HSTS: sudo bash -c 'echo \"add_header Strict-Transport-Security \\\"max-age=31536000; includeSubDomains\\\" always;\" > /etc/nginx/snippets/hsts.conf'"
  fi
fi

# =============================================================================
# VOLUME PERSISTENCE WARNING
# =============================================================================
section "Volume & Data Persistence"

warn "IMPORTANT: Data persistence check."
echo ""
echo "  If your app stores data (databases, uploads, files), it must use"
echo "  named Docker volumes or bind mounts in docker-compose.yml."
echo "  Without these, ALL DATA IS LOST when containers are removed."
echo ""
echo "  Example of a safe named volume in docker-compose.yml:"
echo ""
echo "    volumes:"
echo "      postgres_data:"
echo ""
echo "    services:"
echo "      postgres:"
echo "        volumes:"
echo "          - postgres_data:/var/lib/postgresql/data"
echo ""

read -p "Does your docker-compose.yml already define named volumes for persistent data? (yes/no/na): " HAS_VOLUMES
if [ "$HAS_VOLUMES" = "no" ]; then
  warn "Please update your docker-compose.yml to add named volumes before going to production."
  warn "Continuing — but verify this before storing real user data."
elif [ "$HAS_VOLUMES" = "yes" ]; then
  log "Named volumes confirmed. Data will persist across container restarts."
fi

# =============================================================================
# START THE APP
# =============================================================================
section "Starting $APP_NAME"

cd "$APP_DIR"
docker compose pull 2>/dev/null || true
docker compose up -d --build
log "$APP_NAME containers started."

# =============================================================================
# AUTO-START ON REBOOT (systemd)
# =============================================================================
section "Configuring Auto-start on Reboot"

sudo tee /etc/systemd/system/$APP_NAME.service > /dev/null << EOF
[Unit]
Description=$APP_NAME Docker App
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
User=$DEPLOY_USER
WorkingDirectory=$APP_DIR
ExecStart=/bin/bash -c 'docker compose pull && docker compose up -d --build --remove-orphans'
ExecStop=/usr/bin/docker compose down
RemainAfterExit=yes
Restart=on-failure
RestartSec=10s
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable $APP_NAME
log "$APP_NAME will auto-start on server reboot."

# =============================================================================
# SAVE CONFIG (for future updates)
# =============================================================================
CONFIG_FILE="$DEPLOY_HOME/.${APP_NAME}-config"

cat > "$CONFIG_FILE" << EOF
APP_NAME=$APP_NAME
APP_DIR=$APP_DIR
APP_PORT=$APP_PORT
SOURCE_TYPE=$SOURCE_TYPE
DEPLOY_MODE=$DEPLOY_MODE
DOMAIN_NAME=${DOMAIN_NAME:-}
$([ "${SOURCE_TYPE}" = "github" ] && echo "GITHUB_USER=$GITHUB_USER")
$([ "${SOURCE_TYPE}" = "github" ] && echo "GITHUB_REPO=$GITHUB_REPO")
$([ "${SOURCE_TYPE}" = "github" ] && echo "GITHUB_TOKEN=${GITHUB_TOKEN:-}")
$([ "${SOURCE_TYPE}" = "github" ] && echo "DEPLOY_BRANCH=$DEPLOY_BRANCH")
$([ "${SOURCE_TYPE}" = "dockerhub" ] || [ "${SOURCE_TYPE}" = "ghcr" ] && echo "DOCKER_IMAGE=$DOCKER_IMAGE")
EOF

chmod 600 "$CONFIG_FILE"
log "Config saved to $CONFIG_FILE"

# =============================================================================
# GENERATE UPDATE SCRIPT FOR THIS APP
# =============================================================================
section "Generating Update Script"

UPDATE_SCRIPT="$DEPLOY_HOME/update-${APP_NAME}.sh"

cat > "$UPDATE_SCRIPT" << 'UPDATEEOF'
#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[✔]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✘]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $1${NC}\n${BLUE}══════════════════════════════════════${NC}\n"; }

[ "$EUID" -eq 0 ] && error "Do not run as root."

UPDATEEOF

# Append config-specific update logic
cat >> "$UPDATE_SCRIPT" << EOF
# Load config
source "$CONFIG_FILE"

section "Updating \$APP_NAME"

cd "\$APP_DIR"

case "\$SOURCE_TYPE" in
  github)
    read -p "Branch to update from (ENTER for '\$DEPLOY_BRANCH'): " NEW_BRANCH
    NEW_BRANCH=\${NEW_BRANCH:-\$DEPLOY_BRANCH}
    git remote set-url origin "https://\$GITHUB_TOKEN@github.com/\$GITHUB_USER/\$GITHUB_REPO.git"
    git fetch origin
    git checkout "\$NEW_BRANCH"
    git reset --hard "origin/\$NEW_BRANCH"
    COMMIT=\$(git rev-parse --short HEAD)
    log "Code updated to: \$COMMIT"
    ;;
  dockerhub|ghcr)
    docker compose pull
    log "Latest image pulled."
    ;;
  compose)
    warn "Source is a pasted compose file. Update docker-compose.yml manually at \$APP_DIR/docker-compose.yml"
    ;;
esac

docker compose up -d --build --remove-orphans
log "\$APP_NAME restarted with latest version."

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  \$APP_NAME updated successfully"
if [ -n "\${DOMAIN_NAME:-}" ]; then
echo "  Live at: https://\$DOMAIN_NAME"
else
echo "  Live at: http://\$(curl -s ifconfig.me)"
fi
echo "  Logs: cd \$APP_DIR && docker compose logs -f"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
EOF

chmod +x "$UPDATE_SCRIPT"
log "Update script created: ~/update-${APP_NAME}.sh"

# =============================================================================
# HEALTH CHECK
# =============================================================================
section "Health Check"

warn "Waiting for $APP_NAME to start..."
sleep 5

for i in {1..12}; do
  if curl -sf "http://localhost:$APP_PORT" > /dev/null 2>&1; then
    log "Health check passed. $APP_NAME is responding on port $APP_PORT."
    break
  fi
  [ $i -eq 12 ] && warn "$APP_NAME did not respond after 60s. Check logs below."
  sleep 5
done

# =============================================================================
# DONE
# =============================================================================
section "Deployment Complete!"

PUBLIC_IP=$(curl -s ifconfig.me)

echo -e "${GREEN}$APP_NAME is deployed!${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  App name      : $APP_NAME"
echo "  App directory : $APP_DIR"
if [ -n "${DOMAIN_NAME:-}" ]; then
echo "  URL           : https://$DOMAIN_NAME"
else
echo "  URL           : http://$PUBLIC_IP"
fi
echo "  Source        : $SOURCE_TYPE"
echo "  Deploy mode   : $DEPLOY_MODE"
echo ""
echo "  USEFUL COMMANDS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Update app     : bash ~/update-${APP_NAME}.sh"
echo "  Live logs      : cd $APP_DIR && docker compose logs -f"
echo "  Stop app       : cd $APP_DIR && docker compose down"
echo "  Start app      : cd $APP_DIR && docker compose up -d"
echo "  Restart nginx  : sudo systemctl restart nginx"
echo "  Server status  : vps-status"
echo ""
echo "  ALL DEPLOYED APPS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ls "$APPS_DIR" | while read app; do
  echo "  - $app ($(ls /etc/nginx/sites-enabled/$app 2>/dev/null && echo 'nginx: active' || echo 'nginx: not configured'))"
done
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
