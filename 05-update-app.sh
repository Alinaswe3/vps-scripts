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

# List deployed apps
DEPLOYED_APPS=()
if [ -d "$APPS_DIR" ]; then
  for dir in "$APPS_DIR"/*/; do
    [ -f "${dir}.deploy-info" ] && DEPLOYED_APPS+=("$(basename "$dir")")
  done
fi

if [ ${#DEPLOYED_APPS[@]} -eq 0 ]; then
  error "No deployed apps found. Deploy an app first with 04-deploy-app.sh."
fi

echo "Deployed apps:"
echo ""
for i in "${!DEPLOYED_APPS[@]}"; do
  APP="${DEPLOYED_APPS[$i]}"
  APP_INFO="$APPS_DIR/$APP/.deploy-info"
  DOMAIN=$(grep "^DOMAIN_NAME=" "$APP_INFO" 2>/dev/null | cut -d= -f2-)
  COMMIT=$(grep "^DEPLOYED_COMMIT=" "$APP_INFO" 2>/dev/null | cut -d= -f2-)
  echo "  $((i+1))) $APP ${DOMAIN:+(${DOMAIN})} ${COMMIT:+(commit: ${COMMIT})}"
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

# Load deployment metadata
source "$DEPLOY_INFO"

log "Selected: $APP_NAME"
log "  Directory: $APP_DIR"
log "  Branch: ${GIT_BRANCH:-unknown}"
log "  Domain: ${DOMAIN_NAME:-none}"

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

# Backup .env
[ -f "$APP_DIR/.env" ] && cp "$APP_DIR/.env" "$BACKUP_DIR/.env"

# Backup compose file
[ -f "$APP_DIR/docker-compose.yml" ] && cp "$APP_DIR/docker-compose.yml" "$BACKUP_DIR/docker-compose.yml"
[ -f "$APP_DIR/docker-compose.yaml" ] && cp "$APP_DIR/docker-compose.yaml" "$BACKUP_DIR/docker-compose.yaml"

# Backup deploy-info
cp "$DEPLOY_INFO" "$BACKUP_DIR/.deploy-info"

# Record currently running image digests — used to identify what to rollback to
cd "$APP_DIR"
docker compose ps --format "{{.Image}}" 2>/dev/null > "$BACKUP_DIR/running-images.txt" || true

chown -R "$DEPLOY_USER:$DEPLOY_USER" "$BACKUP_DIR"
log "Backup saved to $BACKUP_DIR"

# =============================================================================
# UPDATE IMAGE
# =============================================================================
if [ "$UPDATE_CODE" = true ]; then
  section "Pulling New Image"

  cd "$APP_DIR"

  # Load registry info
  REGISTRY_IMAGE=""
  [ -f "$APP_DIR/.registry-info" ] && source "$APP_DIR/.registry-info"

  # Fall back to reading image from compose file if .registry-info missing
  if [ -z "$REGISTRY_IMAGE" ]; then
    REGISTRY_IMAGE=$(grep "^\s*image:" "$APP_DIR/docker-compose.yml" 2>/dev/null | head -1 | awk '{print $2}')
  fi
  [ -z "$REGISTRY_IMAGE" ] && error "Could not determine registry image. Check your docker-compose.yml has an 'image:' line."

  # Strip tag to get base image name
  IMAGE_BASE="${REGISTRY_IMAGE%:*}"

  echo "Current image : $REGISTRY_IMAGE"
  echo ""
  read -p "Image tag to deploy (press ENTER for 'latest'): " DEPLOY_TAG
  DEPLOY_TAG=${DEPLOY_TAG:-latest}

  FULL_IMAGE="${IMAGE_BASE}:${DEPLOY_TAG}"

  echo "Pulling $FULL_IMAGE..."
  docker pull "$FULL_IMAGE" || error "Failed to pull $FULL_IMAGE. Check the tag exists in the registry."
  log "Image pulled: $FULL_IMAGE"

  # Update image reference in docker-compose.yml
  sed -i "s|image: .*$(basename "$IMAGE_BASE").*|image: $FULL_IMAGE|" "$APP_DIR/docker-compose.yml" || true

  # Update .registry-info with new tag
  sed -i "s|^REGISTRY_IMAGE=.*|REGISTRY_IMAGE=$FULL_IMAGE|" "$APP_DIR/.registry-info" 2>/dev/null || \
    echo "REGISTRY_IMAGE=$FULL_IMAGE" >> "$APP_DIR/.registry-info"
fi

# =============================================================================
# UPDATE ENVIRONMENT VARIABLES
# =============================================================================
if [ "$UPDATE_ENV" = true ]; then
  section "Updating Environment Variables"

  ENV_FILE="$APP_DIR/.env"

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
          warn "Format must be KEY=VALUE."
        fi
      done
      chmod 600 "$ENV_FILE"
      log "Environment file created."
    fi
  fi
fi

# =============================================================================
# REBUILD & RESTART
# =============================================================================
section "Step 4/4 — Rebuilding & Restarting"

cd "$APP_DIR"

echo "Stopping current containers..."
docker compose down 2>&1

echo "Starting containers with new version..."
docker compose up -d --remove-orphans 2>&1

# Health check
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

# =============================================================================
# ROLLBACK IF FAILED
# =============================================================================
if [ "$APP_HEALTHY" = false ]; then
  echo ""
  warn "App does not appear to be running."
  echo ""
  echo "Recent container logs:"
  echo "───────────────────────────────────────────────"
  docker compose logs --tail=20 2>/dev/null || true
  echo "───────────────────────────────────────────────"
  echo ""

  read -p "Roll back to the previous version? (y/n): " DO_ROLLBACK

  if [ "$DO_ROLLBACK" = "y" ]; then
    section "Rolling Back"

    echo "Stopping failed containers..."
    docker compose down 2>&1 || true

    # Restore .env
    if [ -f "$BACKUP_DIR/.env" ]; then
      cp "$BACKUP_DIR/.env" "$APP_DIR/.env"
      chmod 600 "$APP_DIR/.env"
      log "Environment variables restored."
    fi

    # Restore docker-compose.yml (has previous image tag)
    [ -f "$BACKUP_DIR/docker-compose.yml" ] && cp "$BACKUP_DIR/docker-compose.yml" "$APP_DIR/docker-compose.yml"
    [ -f "$BACKUP_DIR/docker-compose.yaml" ] && cp "$BACKUP_DIR/docker-compose.yaml" "$APP_DIR/docker-compose.yaml"

    # Show what image was running before
    if [ -f "$BACKUP_DIR/running-images.txt" ]; then
      PREV_IMAGE=$(head -1 "$BACKUP_DIR/running-images.txt")
      warn "Previous image was: $PREV_IMAGE"
      warn "Pulling previous image for rollback..."
      docker pull "$PREV_IMAGE" 2>/dev/null || warn "Could not pull previous image — it may no longer exist in the registry."
    fi

    echo "Starting previous version..."
    docker compose up -d --remove-orphans 2>&1

    sleep 5
    if docker compose ps 2>/dev/null | grep -q "Up\|running"; then
      log "Rollback successful. App is running on the previous version."
    else
      error "Rollback also failed. Check logs: cd $APP_DIR && docker compose logs"
    fi
  else
    warn "Not rolling back. Debug with: cd $APP_DIR && docker compose logs"
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