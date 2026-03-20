#!/bin/bash

# =============================================================================
# 05-update-app.sh
# Update a Deployed App (Code, Env, or Both)
# =============================================================================
#
# PURPOSE:
#   Pull latest code from git, update environment variables, rebuild and
#   restart containers. Automatically backs up the current state before
#   any changes so you can roll back if something breaks.
#
# DEPENDENCIES:
#   - App must have been deployed with 04-deploy-app.sh
#
# USAGE:
#   sudo bash 05-update-app.sh
#
# SAFE TO RE-RUN:
#   Yes — creates a new backup each time.
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
  if [ "${LOCAL_MODE:-false}" = "true" ]; then
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

[ "$EUID" -ne 0 ] && error "This script must be run as root. Use: sudo bash 05-update-app.sh"

if ! command -v docker &>/dev/null; then
  error "Docker is not installed. Run 02-docker-install.sh first."
fi

# Detect deploy user
DEPLOY_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home/ {print $1; exit}' /etc/passwd)
[ -z "$DEPLOY_USER" ] && error "No deploy user found."
DEPLOY_HOME="/home/$DEPLOY_USER"
APPS_DIR="$DEPLOY_HOME/apps"

# =============================================================================
# WELCOME BANNER
# =============================================================================
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  APP UPDATE SCRIPT${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  This script will:"
echo "    1. Back up your current .env and compose file"
echo "    2. Pull latest image (registry) or update env vars"
echo "    3. Restart containers with new version"
echo "    4. Roll back automatically if the app fails to start"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# =============================================================================
# SELECT APP
# =============================================================================
section "Step 1/4 — Select App to Update"

DEPLOYED_APPS=()
if [ -d "$APPS_DIR" ]; then
  for dir in "$APPS_DIR"/*/; do
    [ -f "${dir}.deploy-info" ] && DEPLOYED_APPS+=("$(basename "$dir")")
  done
fi

[ ${#DEPLOYED_APPS[@]} -eq 0 ] && error "No deployed apps found. Deploy one first with 04-deploy-app.sh."

echo "Deployed apps:"
echo ""
for i in "${!DEPLOYED_APPS[@]}"; do
  APP="${DEPLOYED_APPS[$i]}"
  APP_INFO="$APPS_DIR/$APP/.deploy-info"
  COMMIT=$(grep "^DEPLOYED_COMMIT=" "$APP_INFO" 2>/dev/null | cut -d= -f2-)
  BRANCH=$(grep "^GIT_BRANCH=" "$APP_INFO" 2>/dev/null | cut -d= -f2-)
  echo "  $((i+1))) $APP ${BRANCH:+(branch: $BRANCH)} ${COMMIT:+(commit: $COMMIT)}"
done
echo ""

while true; do
  read -p "Select app number: " APP_NUM
  if [[ "$APP_NUM" =~ ^[0-9]+$ ]] && [ "$APP_NUM" -ge 1 ] && [ "$APP_NUM" -le ${#DEPLOYED_APPS[@]} ]; then
    APP_NAME="${DEPLOYED_APPS[$((APP_NUM-1))]}"
    break
  fi
  warn "Invalid selection. Enter a number between 1 and ${#DEPLOYED_APPS[@]}."
done

APP_DIR="$APPS_DIR/$APP_NAME"
DEPLOY_INFO="$APP_DIR/.deploy-info"

source "$DEPLOY_INFO"

log "Selected : $APP_NAME"
log "Branch   : ${GIT_BRANCH:-unknown}"
log "Commit   : ${DEPLOYED_COMMIT:-unknown}"
log "Compose  : ${COMPOSE_FILENAME:-docker-compose.yml}"

# =============================================================================
# WHAT TO UPDATE
# =============================================================================
section "Step 2/4 — What to Update"

echo "What would you like to update?"
echo ""
echo "  1) Image      — pull a new image tag from registry, restart"
echo "  2) Env vars   — edit environment variables, restart containers"
echo "  3) Both       — pull new image and update env vars"
echo ""

while true; do
  read -p "Select [1-3]: " UPDATE_TYPE
  case "$UPDATE_TYPE" in
    1) UPDATE_CODE=true;  UPDATE_ENV=false; break ;;
    2) UPDATE_CODE=false; UPDATE_ENV=true;  break ;;
    3) UPDATE_CODE=true;  UPDATE_ENV=true;  break ;;
    *) warn "Enter 1, 2, or 3." ;;
  esac
done

# =============================================================================
# BACKUP
# =============================================================================
section "Step 3/4 — Backing Up Current State"

BACKUP_DIR="$APP_DIR/.backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "Creating backup before update..."

# Use compose location from deploy-info, fall back to app dir
_BACKUP_COMPOSE_DIR="${COMPOSE_DIR:-$APP_DIR}"
_BACKUP_COMPOSE_FILE="${COMPOSE_FILENAME:-docker-compose.yml}"

# Backup .env (lives next to the compose file)
[ -f "$_BACKUP_COMPOSE_DIR/.env" ] && cp "$_BACKUP_COMPOSE_DIR/.env" "$BACKUP_DIR/.env"

# Backup compose file
[ -f "$_BACKUP_COMPOSE_DIR/$_BACKUP_COMPOSE_FILE" ] && cp "$_BACKUP_COMPOSE_DIR/$_BACKUP_COMPOSE_FILE" "$BACKUP_DIR/$_BACKUP_COMPOSE_FILE"

# Backup deploy-info
cp "$DEPLOY_INFO" "$BACKUP_DIR/.deploy-info"

# Record currently running image digests — used to identify what to rollback to
cd "$_BACKUP_COMPOSE_DIR"
docker compose -f "$_BACKUP_COMPOSE_FILE" ps --format "{{.Image}}" 2>/dev/null > "$BACKUP_DIR/running-images.txt" || true

chown -R "$DEPLOY_USER:$DEPLOY_USER" "$BACKUP_DIR"
log "Backup saved to $BACKUP_DIR"

# =============================================================================
# UPDATE IMAGE
# =============================================================================
if [ "$UPDATE_CODE" = true ]; then
  section "Pulling New Image"

  # Use compose location from deploy-info, fall back to app dir
  COMPOSE_DIR="${COMPOSE_DIR:-$APP_DIR}"
  COMPOSE_FILENAME="${COMPOSE_FILENAME:-docker-compose.yml}"

  cd "$COMPOSE_DIR"

  # Detect private images and offer registry login
  PRIVATE_IMAGES=$(grep -E "^\s+image:\s+ghcr\.io|^\s+image:\s+[a-z0-9.-]+\.[a-z]{2,}/[^/]+/" \
    "$COMPOSE_FILENAME" 2>/dev/null | awk '{print $2}' || true)

  if [ -n "$PRIVATE_IMAGES" ]; then
    echo "Private registry image(s) detected:"
    echo "$PRIVATE_IMAGES" | sed 's/^/  /'
    echo ""
    read -p "Log in to registry before pulling? (y/n): " DO_LOGIN
    if [ "$DO_LOGIN" = "y" ]; then
      FIRST_IMAGE=$(echo "$PRIVATE_IMAGES" | head -1)
      DEFAULT_HOST=$(echo "$FIRST_IMAGE" | cut -d'/' -f1)
      read -p "Registry hostname [$DEFAULT_HOST]: " REG_HOST
      REG_HOST="${REG_HOST:-$DEFAULT_HOST}"
      read -p "Registry username: " REG_USER
      read -s -p "Registry token/password: " REG_TOKEN; echo ""
      echo "$REG_TOKEN" | docker login "$REG_HOST" -u "$REG_USER" --password-stdin \
        || error "Registry login failed."
      log "Logged in to $REG_HOST."
    fi
  fi

  # Ask for specific image tag if registry image present
  if [ -n "$PRIVATE_IMAGES" ]; then
    IMAGE_BASE=$(echo "$PRIVATE_IMAGES" | head -1 | sed 's/:.*//')
    CURRENT_TAG=$(echo "$PRIVATE_IMAGES" | head -1 | grep -o ':.*' | sed 's/://' || echo "latest")
    echo ""
    echo "  Current tag: $CURRENT_TAG"
    read -p "  Tag to deploy (press ENTER for '$CURRENT_TAG'): " DEPLOY_TAG
    DEPLOY_TAG="${DEPLOY_TAG:-$CURRENT_TAG}"

    if [ "$DEPLOY_TAG" != "$CURRENT_TAG" ]; then
      FULL_IMAGE="${IMAGE_BASE}:${DEPLOY_TAG}"
      echo "  Updating image tag to $FULL_IMAGE in $COMPOSE_FILENAME..."
      sed -i "s|image: ${IMAGE_BASE}:${CURRENT_TAG}|image: $FULL_IMAGE|g" "$COMPOSE_FILENAME" || true
    fi
  fi

  echo "Pulling latest images..."
  docker compose -f "$COMPOSE_FILENAME" pull \
    || warn "Some images could not be pulled. Check registry credentials."
  log "Images pulled."
fi

# =============================================================================
# UPDATE ENVIRONMENT VARIABLES
# =============================================================================
if [ "$UPDATE_ENV" = true ]; then
  section "Updating Environment Variables"

  ENV_FILE="${COMPOSE_DIR:-$APP_DIR}/.env"

  if [ -f "$ENV_FILE" ]; then
    echo "Current environment variables:"
    echo ""

    # Display vars with sensitive values masked
    LINE_NUM=0
    declare -a ENV_KEYS=()
    while IFS= read -r line || [ -n "$line" ]; do
      LINE_NUM=$((LINE_NUM + 1))
      # Skip comments and empty lines
      if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      KEY=$(echo "$line" | cut -d= -f1 | xargs)
      VALUE=$(echo "$line" | cut -d= -f2-)
      ENV_KEYS+=("$KEY")

      # Mask values that look sensitive
      if echo "$KEY" | grep -qiE "(password|secret|token|key|api)"; then
        DISPLAY_VAL="********"
      else
        DISPLAY_VAL="$VALUE"
      fi

      echo "  $LINE_NUM) $KEY = $DISPLAY_VAL"
    done < "$ENV_FILE"

    echo ""
    echo "Options:"
    echo "  - Enter a number to edit that variable"
    echo "  - Type 'add' to add a new variable"
    echo "  - Type 'done' when finished"
    echo ""

    while true; do
      read -p "Action (number/add/done): " ENV_ACTION

      if [ "$ENV_ACTION" = "done" ]; then
        break
      elif [ "$ENV_ACTION" = "add" ]; then
        read -p "  New variable (KEY=VALUE): " NEW_VAR
        if [[ "$NEW_VAR" == *"="* ]]; then
          echo "$NEW_VAR" >> "$ENV_FILE"
          log "Variable added."
        else
          warn "Format must be KEY=VALUE."
        fi
      elif [[ "$ENV_ACTION" =~ ^[0-9]+$ ]]; then
        # Find the Nth non-comment line
        TARGET_KEY=""
        COUNT=0
        while IFS= read -r line || [ -n "$line" ]; do
          [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
          COUNT=$((COUNT + 1))
          if [ "$COUNT" -eq "$ENV_ACTION" ]; then
            TARGET_KEY=$(echo "$line" | cut -d= -f1 | xargs)
            break
          fi
        done < "$ENV_FILE"

        if [ -n "$TARGET_KEY" ]; then
          read -p "  New value for $TARGET_KEY: " NEW_VALUE
          # Use a temp file to avoid sed issues with special characters
          TEMP_ENV=$(mktemp)
          while IFS= read -r line || [ -n "$line" ]; do
            LINE_KEY=$(echo "$line" | cut -d= -f1 | xargs)
            if [ "$LINE_KEY" = "$TARGET_KEY" ]; then
              echo "${TARGET_KEY}=${NEW_VALUE}"
            else
              echo "$line"
            fi
          done < "$ENV_FILE" > "$TEMP_ENV"
          mv "$TEMP_ENV" "$ENV_FILE"
          chmod 600 "$ENV_FILE"
          log "$TARGET_KEY updated."
        else
          warn "Invalid number."
        fi
      else
        warn "Enter a number, 'add', or 'done'."
      fi
    done

    log "Environment variables updated."
  else
    read -p "No .env file exists. Create one? (y/n): " CREATE_ENV
    if [ "$CREATE_ENV" = "y" ]; then
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
      fi
    fi
  fi
fi

# =============================================================================
# REBUILD & RESTART
# =============================================================================
section "Step 4/4 — Restarting"

_COMPOSE_DIR="${COMPOSE_DIR:-$APP_DIR}"
_COMPOSE_FILE="${COMPOSE_FILENAME:-docker-compose.yml}"
cd "$_COMPOSE_DIR"

echo "Stopping current containers..."
docker compose -f "$_COMPOSE_FILE" down 2>&1

echo "Starting containers with new version..."
docker compose -f "$_COMPOSE_FILE" up -d --remove-orphans 2>&1

# Health check
echo ""
echo "Waiting for app to start..."
sleep 5

APP_HEALTHY=false
for i in {1..12}; do
  if docker compose -f "$_COMPOSE_FILE" ps 2>/dev/null | grep -q "Up\|running"; then
    APP_HEALTHY=true
    break
  fi
  echo "  Checking... (attempt $i/12)"
  sleep 5
done

# =============================================================================
# ROLLBACK IF FAILED
# =============================================================================
if [ "$APP_HEALTHY" = false ]; then
  echo ""
  warn "App does not appear to be running."
  echo ""
  echo "Recent container logs:"
  echo "───────────────────────────────────────────────"
  docker compose -f "$_COMPOSE_FILE" logs --tail=20 2>/dev/null || true
  echo "───────────────────────────────────────────────"
  echo ""

  read -p "Roll back to the previous version? (y/n): " DO_ROLLBACK

  if [ "$DO_ROLLBACK" = "y" ]; then
    section "Rolling Back"

    echo "Stopping failed containers..."
    docker compose -f "$_COMPOSE_FILE" down 2>&1 || true

    # Restore .env
    if [ -f "$BACKUP_DIR/.env" ]; then
      cp "$BACKUP_DIR/.env" "$_COMPOSE_DIR/.env"
      chmod 600 "$_COMPOSE_DIR/.env"
      log "Environment variables restored."
    fi

    # Restore compose file (has previous image tag)
    [ -f "$BACKUP_DIR/docker-compose.yml" ] && cp "$BACKUP_DIR/docker-compose.yml" "$_COMPOSE_DIR/docker-compose.yml"
    [ -f "$BACKUP_DIR/docker-compose.yaml" ] && cp "$BACKUP_DIR/docker-compose.yaml" "$_COMPOSE_DIR/docker-compose.yaml"

    # Pull previous image if known
    if [ -f "$BACKUP_DIR/running-images.txt" ]; then
      PREV_IMAGE=$(head -1 "$BACKUP_DIR/running-images.txt")
      warn "Previous image: $PREV_IMAGE"
      docker pull "$PREV_IMAGE" 2>/dev/null \
        || warn "Could not pull previous image — it may no longer exist in the registry."
    fi

    echo "Starting previous version..."
    docker compose -f "$_COMPOSE_FILE" up -d --remove-orphans 2>&1

    sleep 5
    if docker compose -f "$_COMPOSE_FILE" ps 2>/dev/null | grep -q "Up\|running"; then
      log "Rollback successful."
    else
      error "Rollback also failed. Check logs: cd $_COMPOSE_DIR && docker compose -f $_COMPOSE_FILE logs"
    fi
  else
    warn "Not rolling back. Debug with: cd $_COMPOSE_DIR && docker compose -f $_COMPOSE_FILE logs"
  fi
else
  log "App is running."
fi

# =============================================================================
# UPDATE DEPLOY INFO
# =============================================================================
if [ "$APP_HEALTHY" = true ]; then
  sed -i "s/^DEPLOYED_AT=.*/DEPLOYED_AT=$(date -u +"%Y-%m-%d %H:%M:%S UTC")/" "$DEPLOY_INFO" 2>/dev/null || true
  chown -R "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR"
fi

# =============================================================================
# DONE
# =============================================================================
SERVER_IP=$(get_server_ip)

if [ "${LOCAL_MODE:-false}" = "true" ]; then
  APP_URL="http://localhost:8080 (via VirtualBox port forwarding)"
elif [ "${SSL_ACTIVE:-false}" = "true" ] && [ -n "${DOMAIN_NAME:-}" ]; then
  APP_URL="https://$DOMAIN_NAME"
elif [ -n "${DOMAIN_NAME:-}" ]; then
  APP_URL="http://$DOMAIN_NAME"
else
  APP_URL="http://$SERVER_IP"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  UPDATE COMPLETE${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  App name      : $APP_NAME"
echo "  App URL       : $APP_URL"
if [ "$UPDATE_CODE" = true ]; then
echo "  Image deployed: ${FULL_IMAGE:-latest}"
fi
echo "  Backup saved  : $BACKUP_DIR"
echo ""
echo "  USEFUL COMMANDS"
echo "  ───────────────────────────────────────────────"
echo "  View logs      : cd $APP_DIR && docker compose logs -f"
echo "  Restart app    : cd $APP_DIR && docker compose restart"
echo "  Update again   : sudo bash 05-update-app.sh"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"