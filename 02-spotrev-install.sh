#!/bin/bash

# =============================================================================
# 02-spotrev-install.sh
# SpotRev Installation Script
# -----------------------------------------------------------------------------
# Run this AFTER 01-vps-setup.sh on a VPS that already has Docker installed.
# Clones SpotRev, sets up nginx, SSL, .env, and starts all containers.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[✔]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✘]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $1${NC}\n${BLUE}══════════════════════════════════════${NC}\n"; }

# --- Must NOT run as root (must be the deploy user) ---
[ "$EUID" -eq 0 ] && error "Do not run as root. Run as your deploy user: bash 02-spotrev-install.sh"

# --- Docker must be installed ---
command -v docker &>/dev/null || error "Docker is not installed. Run 01-vps-setup.sh first."

# --- Docker Compose must be available ---
docker compose version &>/dev/null || error "Docker Compose plugin not found. Run 01-vps-setup.sh first."

DEPLOY_USER=$(whoami)
DEPLOY_HOME="/home/$DEPLOY_USER"

# =============================================================================
# COLLECT INFORMATION
# =============================================================================
section "SpotRev Installation — Gathering Information"

echo "This script installs SpotRev on this VPS."
echo ""

# GitHub username
read -p "GitHub username: " GITHUB_USER
[ -z "$GITHUB_USER" ] && error "GitHub username cannot be empty."

# GitHub repo name
read -p "GitHub repository name (e.g. spotrev): " GITHUB_REPO
[ -z "$GITHUB_REPO" ] && error "Repository name cannot be empty."

# GitHub Personal Access Token
warn "You need a GitHub Personal Access Token to clone a private repo."
warn "Generate one at: github.com/settings/tokens (scope: repo)"
read -s -p "GitHub Personal Access Token: " GITHUB_TOKEN; echo ""
[ -z "$GITHUB_TOKEN" ] && error "GitHub token cannot be empty."

# App port
read -p "Port your SvelteKit app runs on inside Docker (e.g. 3000): " APP_PORT
[[ ! "$APP_PORT" =~ ^[0-9]+$ ]] && error "Invalid port."

# Domain name
read -p "Domain name (e.g. spotrev.com) or press ENTER to use IP only: " DOMAIN_NAME

# Install directory
APP_DIR="$DEPLOY_HOME/apps/spotrev"

# .env contents
echo ""
warn "Paste your .env file contents below."
warn "Press ENTER on a new line, paste everything, then press CTRL+D when done:"
echo "--- START PASTE ---"
ENV_CONTENTS=$(cat)
echo "--- END PASTE ---"
[ -z "$ENV_CONTENTS" ] && error ".env cannot be empty."

echo ""
log "Information collected. Starting SpotRev installation..."
sleep 1

# =============================================================================
# CLONE REPOSITORY
# =============================================================================
section "Cloning SpotRev from GitHub"

mkdir -p "$DEPLOY_HOME/apps"

if [ -d "$APP_DIR" ]; then
  warn "Directory $APP_DIR already exists."
  read -p "Remove and re-clone? (yes/no): " RECLONE
  [ "$RECLONE" = "yes" ] && rm -rf "$APP_DIR" || error "Aborting. Remove $APP_DIR manually and re-run."
fi

git clone "https://$GITHUB_TOKEN@github.com/$GITHUB_USER/$GITHUB_REPO.git" "$APP_DIR"
log "Repository cloned to $APP_DIR"

# Store credentials securely for future pulls
git -C "$APP_DIR" remote set-url origin "https://$GITHUB_TOKEN@github.com/$GITHUB_USER/$GITHUB_REPO.git"

# =============================================================================
# WRITE .env FILE
# =============================================================================
section "Writing .env File"

echo "$ENV_CONTENTS" > "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"
log ".env file written and secured (chmod 600)."

# =============================================================================
# NGINX CONFIGURATION
# =============================================================================
section "Configuring nginx for SpotRev"

if [ -n "$DOMAIN_NAME" ]; then
  SERVER_NAME="$DOMAIN_NAME www.$DOMAIN_NAME"
else
  SERVER_NAME="_"
  warn "No domain provided. SpotRev will be served on the server IP."
fi

sudo tee /etc/nginx/sites-available/spotrev > /dev/null << EOF
server {
    listen 80;
    server_name $SERVER_NAME;

    # Hide nginx version
    server_tokens off;

    # Security headers (from global snippet)
    include snippets/security-headers.conf;

    # Max upload size
    client_max_body_size 20M;

    # Rate limiting — protect against abuse
    limit_req_zone \$binary_remote_addr zone=spotrev:10m rate=30r/m;
    limit_req zone=spotrev burst=10 nodelay;

    # SpotRev app
    location / {
        proxy_pass http://localhost:$APP_PORT;
        include snippets/proxy-params.conf;
    }

    # Block hidden files (.env, .git, etc.)
    location ~ /\. {
        deny all;
        return 404;
    }

    # Block access to sensitive files
    location ~* \.(env|log|sh|sql|bak)$ {
        deny all;
        return 404;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/spotrev /etc/nginx/sites-enabled/spotrev
sudo nginx -t && sudo systemctl reload nginx
log "nginx configured for SpotRev."

# =============================================================================
# SSL CERTIFICATE
# =============================================================================
if [ -n "$DOMAIN_NAME" ]; then
  section "Setting Up SSL for $DOMAIN_NAME"

  warn "Your domain DNS A record must point to this server's IP before SSL works."
  PUBLIC_IP=$(curl -s ifconfig.me)
  echo "  This server's IP: $PUBLIC_IP"
  echo ""
  read -p "Has $DOMAIN_NAME DNS been pointed to $PUBLIC_IP? (yes/no): " DNS_READY

  if [ "$DNS_READY" = "yes" ]; then
    read -p "Enter your email for SSL certificate renewal alerts: " SSL_EMAIL

    # Dry run first — catches DNS issues before making any real changes
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
      log "SSL certificate installed. Auto-renewal is active."

      # Add HSTS now that SSL is confirmed working
      sudo tee /etc/nginx/snippets/hsts.conf > /dev/null << EOF
# HSTS — tells browsers to always use HTTPS for this domain
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF
      sudo sed -i "/include snippets\/security-headers.conf;/a\\    include snippets/hsts.conf;" \
        /etc/nginx/sites-available/spotrev
      sudo nginx -t && sudo systemctl reload nginx
      log "HSTS header added. Browsers will now enforce HTTPS."
    else
      error "SSL dry-run failed. Check that $DOMAIN_NAME DNS A record points to $PUBLIC_IP and try again."
    fi
  else
    warn "Skipping SSL for now. Run this when DNS is ready:"
    warn "sudo certbot --nginx -d $DOMAIN_NAME -d www.$DOMAIN_NAME"
    warn "Then add HSTS manually after SSL works."
  fi
fi

# =============================================================================
# VOLUME PERSISTENCE CHECK
# =============================================================================
section "Volume & Data Persistence"

warn "IMPORTANT: SpotRev stores real user data in PostgreSQL."
echo ""
echo "  Your docker-compose.yml must use named volumes for PostgreSQL,"
echo "  otherwise ALL DATA IS LOST when containers are removed."
echo ""
echo "  Required in your docker-compose.yml:"
echo ""
echo "    volumes:"
echo "      postgres_data:"
echo ""
echo "    services:"
echo "      postgres:"
echo "        volumes:"
echo "          - postgres_data:/var/lib/postgresql/data"
echo ""

read -p "Does your docker-compose.yml define a named volume for PostgreSQL? (yes/no): " HAS_VOLUMES
if [ "$HAS_VOLUMES" = "no" ]; then
  warn "⚠ HIGH RISK: Add named volumes to your docker-compose.yml before going live."
  warn "Continuing install — but do not store real user data until this is fixed."
else
  log "Named volumes confirmed. PostgreSQL data will persist across restarts."
fi

# =============================================================================
# START SPOTREV
# =============================================================================
section "Starting SpotRev"

cd "$APP_DIR"
docker compose pull
docker compose up -d --build
log "SpotRev containers started."

# =============================================================================
# AUTO-START ON REBOOT
# =============================================================================
section "Configuring Auto-start on Reboot"

sudo tee /etc/systemd/system/spotrev.service > /dev/null << EOF
[Unit]
Description=SpotRev
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
sudo systemctl enable spotrev
log "SpotRev will auto-start on server reboot."

# =============================================================================
# SAVE CONFIG FOR DEPLOY SCRIPT
# =============================================================================
cat > "$DEPLOY_HOME/.spotrev-config" << EOF
GITHUB_USER=$GITHUB_USER
GITHUB_REPO=$GITHUB_REPO
GITHUB_TOKEN=$GITHUB_TOKEN
APP_DIR=$APP_DIR
APP_PORT=$APP_PORT
DOMAIN_NAME=$DOMAIN_NAME
EOF
chmod 600 "$DEPLOY_HOME/.spotrev-config"
log "SpotRev config saved to ~/.spotrev-config (used by deploy script)."

# =============================================================================
# DONE
# =============================================================================
section "SpotRev Installation Complete!"

PUBLIC_IP=$(curl -s ifconfig.me)

echo -e "${GREEN}SpotRev is live!${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SPOTREV"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -n "$DOMAIN_NAME" ]; then
echo "  URL           : https://$DOMAIN_NAME"
else
echo "  URL           : http://$PUBLIC_IP"
fi
echo "  App directory : $APP_DIR"
echo "  App port      : $APP_PORT"
echo ""
echo "  USEFUL COMMANDS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Deploy update  : bash 03-spotrev-deploy.sh"
echo "  View all logs  : cd $APP_DIR && docker compose logs -f"
echo "  View app logs  : cd $APP_DIR && docker compose logs -f app"
echo "  DB logs        : cd $APP_DIR && docker compose logs -f postgres"
echo "  Stop SpotRev   : cd $APP_DIR && docker compose down"
echo "  Start SpotRev  : cd $APP_DIR && docker compose up -d"
echo "  Server status  : vps-status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
