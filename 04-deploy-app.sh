#!/bin/bash

# =============================================================================
# 04-deploy-app.sh
# Deploy a Dockerized App from a Git Repository
# =============================================================================
#
# PURPOSE:
#   Clone a git repo, optionally configure environment variables,
#   log into any private registries, and start the app with Docker.
#
# DEPENDENCIES:
#   - Docker + Docker Compose plugin (02-docker-install.sh)
#
# USAGE:
#   sudo bash 04-deploy-app.sh
#
# SAFE TO RE-RUN:
#   Yes — detects existing apps and asks before redeploying.
#
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!!]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $1${NC}\n${BLUE}══════════════════════════════════════${NC}\n"; }

# =============================================================================
# PRE-FLIGHT
# =============================================================================

[ "$EUID" -ne 0 ] && error "Run as root: sudo bash 04-deploy-app.sh"
command -v docker &>/dev/null || error "Docker not installed. Run 02-docker-install.sh first."
docker compose version &>/dev/null || error "Docker Compose plugin not found. Run 02-docker-install.sh first."
command -v git &>/dev/null || error "Git not installed. Run: sudo apt install -y git"

DEPLOY_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home/ {print $1; exit}' /etc/passwd)
[ -z "$DEPLOY_USER" ] && error "No deploy user found. Run 01-vps-harden.sh first."
DEPLOY_HOME="/home/$DEPLOY_USER"
APPS_DIR="$DEPLOY_HOME/apps"
mkdir -p "$APPS_DIR"

# --- Auto-detect VirtualBox ---
LOCAL_MODE=false
if [ -f /sys/class/dmi/id/product_name ]; then
  PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
  if echo "$PRODUCT_NAME" | grep -qi "virtualbox"; then
    warn "VirtualBox detected — running in local test mode."
    LOCAL_MODE=true
  fi
fi

# =============================================================================
# WELCOME
# =============================================================================
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  APP DEPLOYMENT${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Deploy user : $DEPLOY_USER"
echo "  Apps dir    : $APPS_DIR"
echo ""

EXISTING_APPS=$(ls "$APPS_DIR" 2>/dev/null | head -20)
if [ -n "$EXISTING_APPS" ]; then
  echo "  Currently deployed:"
  for app in $EXISTING_APPS; do echo "    - $app"; done
  echo ""
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -p "Ready to deploy? (y/n): " START_CONFIRM
[ "$START_CONFIRM" != "y" ] && echo "Aborted." && exit 0

# =============================================================================
# STEP 1: APP NAME
# =============================================================================
section "Step 1/5 — App Name"

while true; do
  read -p "App name (lowercase, no spaces, e.g. spotrev): " APP_NAME
  [[ "$APP_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] && break
  warn "Lowercase letters, numbers, hyphens and underscores only."
done

APP_DIR="$APPS_DIR/$APP_NAME"

if [ -d "$APP_DIR" ]; then
  warn "'$APP_NAME' already exists at $APP_DIR."
  read -p "Remove and redeploy? (y/n): " REDEPLOY
  if [ "$REDEPLOY" = "y" ]; then
    cd "$APP_DIR" && docker compose down 2>/dev/null || true
    cd /
    rm -rf "$APP_DIR"
    log "Previous deployment removed."
  else
    echo "Aborted."
    exit 0
  fi
fi

mkdir -p "$APP_DIR"

# =============================================================================
# STEP 2: CLONE REPOSITORY
# =============================================================================
section "Step 2/5 — Clone Repository"

echo "Provide the HTTPS URL of your git repository."
echo "  Public:  https://github.com/user/repo.git"
echo "  Private: https://github.com/user/repo.git (token required)"
echo ""

read -p "Repository URL: " GIT_URL
[ -z "$GIT_URL" ] && error "Repository URL cannot be empty."

read -p "Branch (press ENTER for 'main'): " GIT_BRANCH
GIT_BRANCH=${GIT_BRANCH:-main}

read -p "Private repository? (y/n): " IS_PRIVATE
GIT_TOKEN=""
if [ "$IS_PRIVATE" = "y" ]; then
  echo ""
  echo "  Generate a token at: github.com/settings/tokens"
  echo "  Required scope: repo (read access)"
  echo ""
  read -s -p "Personal Access Token: " GIT_TOKEN; echo ""
  [ -z "$GIT_TOKEN" ] && error "Token required for private repositories."
fi

echo ""
echo "Cloning $GIT_URL (branch: $GIT_BRANCH)..."

if [ -n "$GIT_TOKEN" ]; then
  CLONE_URL=$(echo "$GIT_URL" | sed "s|https://|https://${GIT_TOKEN}@|")
  git clone --branch "$GIT_BRANCH" "$CLONE_URL" "$APP_DIR" 2>&1 \
    || error "Clone failed. Check your URL, branch, and token."
  # Strip token from remote immediately after clone
  cd "$APP_DIR" && git remote set-url origin "$GIT_URL"
else
  git clone --branch "$GIT_BRANCH" "$GIT_URL" "$APP_DIR" 2>&1 \
    || error "Clone failed. Check your URL and branch."
  cd "$APP_DIR"
fi

log "Cloned successfully. Commit: $(git -C "$APP_DIR" rev-parse --short HEAD)"

# =============================================================================
# STEP 3: CHOOSE COMPOSE FILE
# =============================================================================
section "Step 3/5 — Choose Compose File"

# Find all compose/dockerfile candidates in the repo
echo "Compose and Dockerfile candidates found in repo:"
echo ""
CANDIDATES=()
while IFS= read -r -d '' f; do
  CANDIDATES+=("$(basename "$f")")
  echo "  ${#CANDIDATES[@]}) $(basename "$f")"
done < <(find "$APP_DIR" -maxdepth 2 \( \
  -name "docker-compose.yml" \
  -o -name "docker-compose.yaml" \
  -o -name "docker-compose.*.yml" \
  -o -name "docker-compose.*.yaml" \
  -o -name "compose.yml" \
  -o -name "compose.yaml" \
  -o -name "Dockerfile" \
\) -print0 2>/dev/null | sort -z)

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  error "No docker-compose.yml or Dockerfile found in the repository."
fi

echo ""

COMPOSE_FILE=""
if [ ${#CANDIDATES[@]} -eq 1 ]; then
  COMPOSE_FILE=$(find "$APP_DIR" -maxdepth 2 -name "${CANDIDATES[0]}" | head -1)
  log "Only one file found — using: ${CANDIDATES[0]}"
else
  while true; do
    read -p "Select file [1-${#CANDIDATES[@]}]: " FILE_CHOICE
    if [[ "$FILE_CHOICE" =~ ^[0-9]+$ ]] \
      && [ "$FILE_CHOICE" -ge 1 ] \
      && [ "$FILE_CHOICE" -le ${#CANDIDATES[@]} ]; then
      CHOSEN_NAME="${CANDIDATES[$((FILE_CHOICE-1))]}"
      COMPOSE_FILE=$(find "$APP_DIR" -maxdepth 2 -name "$CHOSEN_NAME" | head -1)
      log "Using: $CHOSEN_NAME"
      break
    fi
    warn "Enter a number between 1 and ${#CANDIDATES[@]}."
  done
fi

# If a Dockerfile was selected, generate a docker-compose.yml for it
if [[ "$(basename "$COMPOSE_FILE")" == "Dockerfile"* ]]; then
  DOCKERFILE_DIR=$(dirname "$COMPOSE_FILE")
  DOCKERFILE_NAME=$(basename "$COMPOSE_FILE")

  echo ""
  read -p "Which port does this app listen on inside the container? (e.g. 3000, 8080): " CONTAINER_PORT
  if ! [[ "$CONTAINER_PORT" =~ ^[0-9]+$ ]]; then
    error "Invalid port number."
  fi

  read -p "Host port to map to (press ENTER for $CONTAINER_PORT): " HOST_PORT
  HOST_PORT="${HOST_PORT:-$CONTAINER_PORT}"

  cat > "$DOCKERFILE_DIR/docker-compose.yml" << DEOF
# Auto-generated from $DOCKERFILE_NAME by 04-deploy-app.sh
services:
  $APP_NAME:
    build:
      context: .
      dockerfile: $DOCKERFILE_NAME
    ports:
      - "127.0.0.1:${HOST_PORT}:${CONTAINER_PORT}"
    restart: unless-stopped
DEOF

  COMPOSE_FILE="$DOCKERFILE_DIR/docker-compose.yml"
  log "Generated docker-compose.yml from $DOCKERFILE_NAME (port ${HOST_PORT}:${CONTAINER_PORT})"
fi

# Normalise — always reference as docker-compose.yml in APP_DIR
COMPOSE_FILENAME=$(basename "$COMPOSE_FILE")
COMPOSE_DIR=$(dirname "$COMPOSE_FILE")

# =============================================================================
# STEP 4: ENVIRONMENT VARIABLES
# =============================================================================
section "Step 4/5 — Environment Variables"

ENV_FILE="$COMPOSE_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  warn ".env already exists in repo — using it as-is."
  warn "Make sure it does not contain real secrets committed to git."
else
  read -p "Does this app need environment variables? (y/n): " NEEDS_ENV
  if [ "$NEEDS_ENV" = "y" ]; then
    echo ""
    echo "Paste your .env contents below (KEY=VALUE format, one per line)."
    echo "Press ENTER on a new line then CTRL+D when done."
    echo ""
    echo "--- START PASTE ---"
    ENV_CONTENTS=$(cat)
    echo "--- END PASTE ---"
    if [ -n "$ENV_CONTENTS" ]; then
      printf '%s\n' "$ENV_CONTENTS" > "$ENV_FILE"
      chmod 600 "$ENV_FILE"
      log ".env saved."
    else
      log "No environment variables configured."
    fi
  else
    log "No .env configured."
  fi
fi

# =============================================================================
# STEP 5: REGISTRY AUTH + PULL + START
# =============================================================================
section "Step 5/5 — Registry Auth & Start"

# Detect private registry images in the chosen compose file
PRIVATE_IMAGES=$(grep -E "^\s+image:\s+ghcr\.io|^\s+image:\s+[a-z0-9.-]+\.[a-z]{2,}/[^/]+/" \
  "$COMPOSE_FILE" 2>/dev/null | awk '{print $2}' || true)

if [ -n "$PRIVATE_IMAGES" ]; then
  echo "Private registry image(s) detected:"
  echo "$PRIVATE_IMAGES" | sed 's/^/  /'
  echo ""
  read -p "Log in to registry before pulling? (y/n): " DO_LOGIN

  if [ "$DO_LOGIN" = "y" ]; then
    # Extract hostname from first image
    FIRST_IMAGE=$(echo "$PRIVATE_IMAGES" | head -1)
    DEFAULT_HOST=$(echo "$FIRST_IMAGE" | cut -d'/' -f1)

    read -p "Registry hostname [$DEFAULT_HOST]: " REG_HOST
    REG_HOST="${REG_HOST:-$DEFAULT_HOST}"
    read -p "Registry username: " REG_USER
    read -s -p "Registry token/password: " REG_TOKEN; echo ""

    echo "$REG_TOKEN" | docker login "$REG_HOST" -u "$REG_USER" --password-stdin \
      || error "Registry login failed. Check your credentials."
    log "Logged in to $REG_HOST."
  fi
fi

# Build/pull images and start
echo ""
cd "$COMPOSE_DIR"

# Check if compose file has build directives and ask user
NEEDS_BUILD=false
if grep -qE '^\s+build:' "$COMPOSE_FILENAME" 2>/dev/null; then
  echo -e "${YELLOW}[!!]${NC} This compose file contains 'build:' directives."
  echo "  Building images on the VPS uses significant CPU and RAM."
  echo "  If you pre-built and pushed images to a registry, choose 'pull'."
  echo ""
  echo "  1) Build on this server  (docker compose up --build)"
  echo "  2) Pull from registry    (docker compose pull + up)"
  echo ""
  read -p "Build or pull? [1/2]: " BUILD_CHOICE
  [ "$BUILD_CHOICE" = "1" ] && NEEDS_BUILD=true
fi

if [ "$NEEDS_BUILD" = true ]; then
  echo "Building images and starting containers..."
  docker compose -f "$COMPOSE_FILENAME" up -d --build --remove-orphans 2>&1
else
  echo "Pulling images and starting containers..."
  docker compose -f "$COMPOSE_FILENAME" pull 2>&1 \
    || warn "Some images could not be pulled — check registry credentials."
  docker compose -f "$COMPOSE_FILENAME" up -d --remove-orphans 2>&1
fi

# Health check
echo ""
echo "Waiting for containers to start..."
sleep 5

APP_HEALTHY=false
for i in {1..12}; do
  if docker compose -f "$COMPOSE_FILENAME" ps 2>/dev/null | grep -q "Up\|running\|healthy"; then
    APP_HEALTHY=true
    break
  fi
  echo "  Checking... ($i/12)"
  sleep 5
done

# =============================================================================
# SAVE DEPLOYMENT METADATA
# =============================================================================
cat > "$APP_DIR/.deploy-info" << EOF
APP_NAME="$APP_NAME"
APP_DIR="$APP_DIR"
COMPOSE_FILE="$COMPOSE_FILE"
COMPOSE_DIR="$COMPOSE_DIR"
COMPOSE_FILENAME="$COMPOSE_FILENAME"
GIT_URL="$GIT_URL"
GIT_BRANCH="$GIT_BRANCH"
IS_PRIVATE="${IS_PRIVATE:-n}"
LOCAL_MODE="$LOCAL_MODE"
DEPLOY_USER="$DEPLOY_USER"
DEPLOYED_AT="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
DEPLOYED_COMMIT="$(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
EOF

chmod 600 "$APP_DIR/.deploy-info"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR"

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ "$APP_HEALTHY" = true ]; then
  echo -e "${GREEN}  DEPLOYMENT COMPLETE${NC}"
else
  echo -e "${YELLOW}  DEPLOYMENT COMPLETE (containers may still be starting)${NC}"
fi

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  App name      : $APP_NAME"
echo "  App directory : $APP_DIR"
echo "  Compose file  : $COMPOSE_FILENAME"
echo "  Git branch    : $GIT_BRANCH"
echo "  Commit        : $(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
echo ""
echo "  USEFUL COMMANDS"
echo "  ───────────────────────────────────────────────"
echo "  View logs   : cd $COMPOSE_DIR && docker compose -f $COMPOSE_FILENAME logs -f"
echo "  Status      : cd $COMPOSE_DIR && docker compose -f $COMPOSE_FILENAME ps"
echo "  Stop        : cd $COMPOSE_DIR && docker compose -f $COMPOSE_FILENAME down"
echo "  Restart     : cd $COMPOSE_DIR && docker compose -f $COMPOSE_FILENAME restart"
echo "  Nginx setup : sudo vps-nginx-config"
echo "  Update      : sudo bash 05-update-app.sh"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"