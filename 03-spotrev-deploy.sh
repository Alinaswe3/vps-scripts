#!/bin/bash

# =============================================================================
# 03-spotrev-deploy.sh
# SpotRev Deploy Script — Pull Latest Changes & Restart
# -----------------------------------------------------------------------------
# Run this every time you want to deploy a new version of SpotRev.
# Pulls from GitHub, rebuilds containers, runs migrations, restarts.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[✔]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✘]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $1${NC}\n${BLUE}══════════════════════════════════════${NC}\n"; }

# --- Must NOT run as root ---
[ "$EUID" -eq 0 ] && error "Do not run as root. Run as your deploy user."

# --- Docker must be available ---
command -v docker &>/dev/null || error "Docker not found."

DEPLOY_HOME="/home/$(whoami)"
CONFIG_FILE="$DEPLOY_HOME/.spotrev-config"

# --- Load saved config from install script ---
[ ! -f "$CONFIG_FILE" ] && error "Config file not found at $CONFIG_FILE. Run 02-spotrev-install.sh first."
source "$CONFIG_FILE"

# =============================================================================
# COLLECT BRANCH
# =============================================================================
section "SpotRev Deploy"

echo "Deploying SpotRev from GitHub."
echo ""
echo "  Repo      : $GITHUB_USER/$GITHUB_REPO"
echo "  Directory : $APP_DIR"
echo ""

read -p "Branch to deploy (press ENTER for 'main'): " BRANCH
BRANCH=${BRANCH:-main}

echo ""
warn "About to deploy branch '$BRANCH' to this server."
read -p "Continue? (yes/no): " CONFIRM
[ "$CONFIRM" != "yes" ] && echo "Aborted." && exit 0

# =============================================================================
# PRE-DEPLOY BACKUP
# =============================================================================
section "Creating Pre-deploy Backup"

BACKUP_DIR="$DEPLOY_HOME/backups/spotrev"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR"

# Backup database
warn "Backing up PostgreSQL database..."
cd "$APP_DIR"

if docker compose ps postgres 2>/dev/null | grep -q "running\|Up"; then
  DB_CONTAINER=$(docker compose ps -q postgres)
  docker exec "$DB_CONTAINER" pg_dumpall -U postgres > "$BACKUP_DIR/db_backup_$TIMESTAMP.sql" 2>/dev/null && \
    log "Database backed up to $BACKUP_DIR/db_backup_$TIMESTAMP.sql" || \
    warn "Database backup failed — continuing anyway."
else
  warn "PostgreSQL container not running, skipping DB backup."
fi

# Keep only last 5 backups
ls -t "$BACKUP_DIR"/db_backup_*.sql 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
log "Old backups cleaned up (keeping last 5)."

# =============================================================================
# PULL LATEST CODE
# =============================================================================
section "Pulling Latest Code from '$BRANCH'"

cd "$APP_DIR"

# Update remote URL with token in case it expired
git remote set-url origin "https://$GITHUB_TOKEN@github.com/$GITHUB_USER/$GITHUB_REPO.git"

# Fetch and reset to remote branch cleanly
git fetch origin
git checkout "$BRANCH"
git reset --hard "origin/$BRANCH"

COMMIT_HASH=$(git rev-parse --short HEAD)
COMMIT_MSG=$(git log -1 --pretty=%s)
log "Code updated to commit: $COMMIT_HASH — $COMMIT_MSG"

# =============================================================================
# CHECK FOR .env CHANGES
# =============================================================================
section "Checking .env File"

if git diff HEAD@{1} HEAD --name-only 2>/dev/null | grep -q "\.env\.example\|\.env\.sample"; then
  warn ".env.example has changed in this update."
  warn "New variables may have been added. Check .env.example and update your .env if needed."
  warn "Current .env is at: $APP_DIR/.env"
  read -p "Press ENTER to continue deploy or CTRL+C to abort and update .env first: "
fi

log ".env file untouched (your secrets are safe)."

# =============================================================================
# REBUILD & RESTART CONTAINERS
# =============================================================================
section "Rebuilding & Restarting Containers"

# Pull latest base images
docker compose pull

# Rebuild app image with new code
docker compose build --no-cache app

# Restart — remove orphan containers from old compose definitions
docker compose up -d --build --remove-orphans

log "Containers rebuilt and restarted."

# =============================================================================
# RUN DATABASE MIGRATIONS (if applicable)
# =============================================================================
section "Running Database Migrations"

# Wait for DB to be ready
warn "Waiting for PostgreSQL to be ready..."
for i in {1..30}; do
  if docker compose exec -T postgres pg_isready -U postgres &>/dev/null; then
    log "PostgreSQL is ready."
    break
  fi
  [ $i -eq 30 ] && error "PostgreSQL did not become ready in time."
  sleep 2
done

# Run Drizzle migrations if migrate script exists in package.json
if docker compose exec -T app sh -c "grep -q '\"migrate\"' package.json" 2>/dev/null; then
  docker compose exec -T app npm run migrate && log "Database migrations ran successfully." || warn "Migration command failed — check logs."
else
  warn "No 'migrate' script found in package.json. Skipping migrations."
fi

# =============================================================================
# HEALTH CHECK
# =============================================================================
section "Running Health Check"

warn "Waiting for app to start..."
sleep 5

APP_PORT_NUM=${APP_PORT:-3000}
for i in {1..12}; do
  if curl -sf "http://localhost:$APP_PORT_NUM" > /dev/null 2>&1; then
    log "Health check passed. App is responding on port $APP_PORT_NUM."
    break
  fi
  [ $i -eq 12 ] && warn "App did not respond after 60s. Check logs: docker compose logs -f app"
  sleep 5
done

# =============================================================================
# DONE
# =============================================================================
section "Deploy Complete!"

echo -e "${GREEN}SpotRev has been updated successfully.${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DEPLOY SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Branch    : $BRANCH"
echo "  Commit    : $COMMIT_HASH — $COMMIT_MSG"
echo "  Time      : $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Backup    : $BACKUP_DIR/db_backup_$TIMESTAMP.sql"
if [ -n "${DOMAIN_NAME:-}" ]; then
echo "  Live at   : https://$DOMAIN_NAME"
else
echo "  Live at   : http://$(curl -s ifconfig.me)"
fi
echo ""
echo "  USEFUL COMMANDS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Live logs  : cd $APP_DIR && docker compose logs -f"
echo "  App logs   : cd $APP_DIR && docker compose logs -f app"
echo "  Rollback   : cd $APP_DIR && git checkout <previous-commit>"
echo "               then: docker compose up -d --build"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
