#!/bin/bash

# =============================================================================
# 08-basic-auth.sh
# Basic Auth Management for Nginx-Proxied Apps
# =============================================================================
#
# PURPOSE:
#   Protect a deployed app behind HTTP basic auth — useful for staging and
#   test environments you don't want the public to stumble into.
#   Manages users (add, remove, list) and can disable auth at any time.
#
# DEPENDENCIES:
#   - Nginx configured for the app (run vps-nginx-config first)
#   - App must have been deployed with 04-deploy-app.sh
#
# USAGE:
#   sudo bash 08-basic-auth.sh
#
# SAFE TO RE-RUN:
#   Yes — detects existing auth config and offers to manage it.
#
# HOW IT WORKS:
#   Adds two lines to the app's nginx location / block:
#     auth_basic "Restricted Access";
#     auth_basic_user_file /etc/nginx/.htpasswd-<app>;
#   Credentials are stored in /etc/nginx/.htpasswd-<app> (one file per app).
#   Disabling auth removes those two lines and deletes the htpasswd file.
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

[ "$EUID" -ne 0 ] && error "Run as root: sudo bash 08-basic-auth.sh"
command -v nginx &>/dev/null || error "Nginx not installed. Run 03-nginx-setup.sh first."

# Install apache2-utils (provides htpasswd) if not present
if ! command -v htpasswd &>/dev/null; then
  echo "Installing apache2-utils (required for htpasswd)..."
  apt install -y apache2-utils > /dev/null 2>&1
  log "apache2-utils installed."
fi

DEPLOY_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home/ {print $1; exit}' /etc/passwd)
APPS_DIR="/home/${DEPLOY_USER:-deploy}/apps"

# =============================================================================
# WELCOME
# =============================================================================
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  BASIC AUTH MANAGER${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Protect apps with a username and password prompt."
echo "  Ideal for staging and test environments."
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# =============================================================================
# SELECT APP
# =============================================================================
section "Step 1 — Select App"

if [ ! -d "$APPS_DIR" ] || [ -z "$(ls -A "$APPS_DIR" 2>/dev/null)" ]; then
  error "No apps deployed. Deploy one first with: sudo bash 04-deploy-app.sh"
fi

APP_LIST=()
INDEX=1
echo "Deployed apps:"
echo ""
for app_dir in "$APPS_DIR"/*/; do
  [ ! -d "$app_dir" ] && continue
  APP=$(basename "$app_dir")
  APP_LIST+=("$APP")

  NGINX_CONF="/etc/nginx/sites-available/$APP"
  AUTH_STATUS="no auth"
  [ -f "$NGINX_CONF" ] && grep -q "auth_basic " "$NGINX_CONF" 2>/dev/null && AUTH_STATUS="auth ENABLED"

  DOMAIN=$(grep "^DOMAIN_NAME=" "$app_dir/.deploy-info" 2>/dev/null | cut -d'"' -f2 || true)
  LABEL="${DOMAIN:-$APP}"

  echo "  $INDEX) $APP  ($LABEL)  [$AUTH_STATUS]"
  ((INDEX++))
done
echo ""

while true; do
  read -p "Select app [1-${#APP_LIST[@]}]: " APP_INDEX
  [[ "$APP_INDEX" =~ ^[0-9]+$ ]] \
    && [ "$APP_INDEX" -ge 1 ] \
    && [ "$APP_INDEX" -le ${#APP_LIST[@]} ] \
    && break
  warn "Enter a number between 1 and ${#APP_LIST[@]}."
done

APP_NAME="${APP_LIST[$((APP_INDEX-1))]}"
NGINX_CONF="/etc/nginx/sites-available/$APP_NAME"
HTPASSWD_FILE="/etc/nginx/.htpasswd-$APP_NAME"

[ ! -f "$NGINX_CONF" ] && error "No nginx config found for '$APP_NAME'. Run: sudo vps-nginx-config"

# =============================================================================
# DETECT CURRENT AUTH STATE
# =============================================================================
AUTH_ENABLED=false
grep -q "auth_basic " "$NGINX_CONF" 2>/dev/null && AUTH_ENABLED=true

# =============================================================================
# MENU
# =============================================================================
section "Step 2 — Action"

echo "  App  : $APP_NAME"
echo "  Auth : $([ "$AUTH_ENABLED" = true ] && echo 'ENABLED' || echo 'disabled')"
echo ""
echo "  1) Enable basic auth    (creates first user, patches nginx)"
echo "  2) Add a user"
echo "  3) Remove a user"
echo "  4) List users"
echo "  5) Disable basic auth   (removes all credentials and nginx config)"
echo ""

while true; do
  read -p "Select [1-5]: " ACTION
  case "$ACTION" in
    1|2|3|4|5) break ;;
    *) warn "Enter a number between 1 and 5." ;;
  esac
done

# =============================================================================
# ACTION: ENABLE
# =============================================================================
if [ "$ACTION" = "1" ]; then
  section "Enabling Basic Auth"

  if [ "$AUTH_ENABLED" = true ]; then
    warn "Basic auth is already enabled for '$APP_NAME'."
    read -p "Add a new user instead? (y/n): " ADD_INSTEAD
    [ "$ADD_INSTEAD" != "y" ] && echo "Nothing changed." && exit 0
    ACTION="2"
  else
    echo "Create the first user for '$APP_NAME'."
    echo ""
    read -p "  Username: " BA_USER
    [ -z "$BA_USER" ] && error "Username cannot be empty."

    # -c creates the file; subsequent users use -B (bcrypt) without -c
    htpasswd -cB "$HTPASSWD_FILE" "$BA_USER" \
      || error "Failed to create htpasswd entry."
    chmod 640 "$HTPASSWD_FILE"
    chown root:www-data "$HTPASSWD_FILE" 2>/dev/null || chown root:root "$HTPASSWD_FILE"

    log "User '$BA_USER' created."

    # Patch nginx: insert auth directives into location / block
    # Inserts immediately after the opening brace of the first "location / {" line
    sed -i '/location \/ {/a\        auth_basic "Restricted Access";\n        auth_basic_user_file '"$HTPASSWD_FILE"';' \
      "$NGINX_CONF"

    if nginx -t 2>&1; then
      systemctl reload nginx
      log "Basic auth enabled for '$APP_NAME'."
    else
      # Rollback the nginx patch if test fails
      sed -i '/auth_basic /d; /auth_basic_user_file /d' "$NGINX_CONF"
      rm -f "$HTPASSWD_FILE"
      error "Nginx config test failed — changes rolled back. Check $NGINX_CONF manually."
    fi

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  BASIC AUTH ENABLED${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  App         : $APP_NAME"
    echo "  First user  : $BA_USER"
    echo "  Credentials : $HTPASSWD_FILE"
    echo ""
    echo "  To add more users : sudo bash 08-basic-auth.sh  → option 2"
    echo "  To disable        : sudo bash 08-basic-auth.sh  → option 5"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 0
  fi
fi

# =============================================================================
# ACTION: ADD USER
# =============================================================================
if [ "$ACTION" = "2" ]; then
  section "Adding User"

  if [ "$AUTH_ENABLED" = false ] && [ ! -f "$HTPASSWD_FILE" ]; then
    error "Basic auth is not enabled for '$APP_NAME'. Run option 1 first."
  fi

  read -p "  Username: " BA_USER
  [ -z "$BA_USER" ] && error "Username cannot be empty."

  # Check if user already exists
  if [ -f "$HTPASSWD_FILE" ] && grep -q "^${BA_USER}:" "$HTPASSWD_FILE" 2>/dev/null; then
    warn "User '$BA_USER' already exists."
    read -p "  Reset their password? (y/n): " RESET_PASS
    [ "$RESET_PASS" != "y" ] && echo "Nothing changed." && exit 0
  fi

  # Add or update user (-B = bcrypt, no -c = append/update, not recreate)
  htpasswd -B "$HTPASSWD_FILE" "$BA_USER" \
    || error "Failed to add user '$BA_USER'."

  log "User '$BA_USER' added/updated."

  TOTAL=$(grep -c "^[^#]" "$HTPASSWD_FILE" 2>/dev/null || echo "?")
  echo "  Total users in $APP_NAME: $TOTAL"
  exit 0
fi

# =============================================================================
# ACTION: REMOVE USER
# =============================================================================
if [ "$ACTION" = "3" ]; then
  section "Removing User"

  [ ! -f "$HTPASSWD_FILE" ] && error "No htpasswd file found for '$APP_NAME'."

  echo "  Current users:"
  grep "^[^#]" "$HTPASSWD_FILE" 2>/dev/null | cut -d: -f1 | sed 's/^/    /' \
    || echo "    (none)"
  echo ""

  read -p "  Username to remove: " BA_USER
  [ -z "$BA_USER" ] && error "Username cannot be empty."

  if ! grep -q "^${BA_USER}:" "$HTPASSWD_FILE" 2>/dev/null; then
    error "User '$BA_USER' not found in $HTPASSWD_FILE."
  fi

  htpasswd -D "$HTPASSWD_FILE" "$BA_USER" \
    || error "Failed to remove user '$BA_USER'."

  log "User '$BA_USER' removed."

  REMAINING=$(grep -c "^[^#]" "$HTPASSWD_FILE" 2>/dev/null || echo "0")
  if [ "$REMAINING" = "0" ]; then
    warn "No users remain. Basic auth is still enabled but no one can log in."
    warn "Add a user (option 2) or disable auth (option 5)."
  else
    echo "  Remaining users: $REMAINING"
  fi
  exit 0
fi

# =============================================================================
# ACTION: LIST USERS
# =============================================================================
if [ "$ACTION" = "4" ]; then
  section "Users for '$APP_NAME'"

  if [ ! -f "$HTPASSWD_FILE" ]; then
    echo "  No htpasswd file found — basic auth has not been enabled."
    exit 0
  fi

  USERS=$(grep "^[^#]" "$HTPASSWD_FILE" 2>/dev/null | cut -d: -f1)
  if [ -z "$USERS" ]; then
    echo "  No users configured."
  else
    echo "  Username"
    echo "  ────────"
    echo "$USERS" | sed 's/^/  /'
    echo ""
    echo "  Total: $(echo "$USERS" | wc -l)"
  fi
  exit 0
fi

# =============================================================================
# ACTION: DISABLE
# =============================================================================
if [ "$ACTION" = "5" ]; then
  section "Disabling Basic Auth"

  if [ "$AUTH_ENABLED" = false ]; then
    warn "Basic auth is not currently enabled for '$APP_NAME'."
    [ -f "$HTPASSWD_FILE" ] && rm -f "$HTPASSWD_FILE" && log "Stale htpasswd file removed."
    exit 0
  fi

  echo "  This will:"
  echo "    - Remove auth_basic directives from nginx config"
  echo "    - Delete $HTPASSWD_FILE (all credentials lost)"
  echo ""
  read -p "  Confirm disable? (y/n): " CONFIRM_DISABLE
  [ "$CONFIRM_DISABLE" != "y" ] && echo "Aborted." && exit 0

  # Remove the two auth lines from the nginx config
  sed -i '/^\s*auth_basic /d; /^\s*auth_basic_user_file /d' "$NGINX_CONF"

  # Delete the credential file
  rm -f "$HTPASSWD_FILE"

  if nginx -t 2>&1; then
    systemctl reload nginx
    log "Basic auth disabled for '$APP_NAME'."
    log "Credentials file deleted: $HTPASSWD_FILE"
  else
    error "Nginx config test failed after disabling auth. Check $NGINX_CONF manually."
  fi

  echo ""
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}  BASIC AUTH DISABLED${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo "  App '$APP_NAME' is now publicly accessible."
  echo "  To re-enable: sudo bash 08-basic-auth.sh → option 1"
  echo ""
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  exit 0
fi
