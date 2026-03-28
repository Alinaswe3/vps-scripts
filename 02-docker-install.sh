#!/bin/bash

# =============================================================================
# 02-docker-install.sh
# Docker Engine + Compose Plugin Installation
# =============================================================================
#
# PURPOSE:
#   Install Docker, Docker Compose plugin, and apply daemon hardening.
#   Adds a specified user to the docker group so they can run containers
#   without sudo.
#
# DEPENDENCIES:
#   None — but we recommend running 01-vps-harden.sh first for a secure base.
#
# NEXT STEP:
#   Run 03-nginx-setup.sh to set up nginx as a reverse proxy.
#
# USAGE:
#   sudo bash 02-docker-install.sh
#
# SAFE TO RE-RUN:
#   Yes — detects existing Docker installation and asks before reinstalling.
#
# =============================================================================

set -euo pipefail

# --- Colors & Logging (self-contained) ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!!]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $1${NC}\n${BLUE}══════════════════════════════════════${NC}\n"; }

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

[ "$EUID" -ne 0 ] && error "This script must be run as root. Use: sudo bash 02-docker-install.sh"

# =============================================================================
# WELCOME BANNER
# =============================================================================
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  DOCKER INSTALLATION SCRIPT${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  This script will:"
echo "    1. Install Docker Engine"
echo "    2. Install Docker Compose plugin"
echo "    3. Add a user to the docker group"
echo "    4. Harden the Docker daemon"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

read -p "Ready to begin? (y/n): " START_CONFIRM
[ "$START_CONFIRM" != "y" ] && echo "Aborted." && exit 0

# =============================================================================
# GATHER INFORMATION
# =============================================================================
section "Step 1/4 — Gathering Information"

# Detect non-root users to suggest
AVAILABLE_USERS=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd 2>/dev/null | tr '\n' ', ' | sed 's/,$//')

if [ -n "$AVAILABLE_USERS" ]; then
  echo "Available users: $AVAILABLE_USERS"
fi

read -p "Which user should be able to run Docker? (e.g. deploy): " DOCKER_USER
[ -z "$DOCKER_USER" ] && error "Username cannot be empty."

if ! id "$DOCKER_USER" &>/dev/null; then
  error "User '$DOCKER_USER' does not exist. Create the user first (run 01-vps-harden.sh or use 'useradd')."
fi

log "Docker will be configured for user '$DOCKER_USER'."

# =============================================================================
# INSTALL DOCKER
# =============================================================================
section "Step 2/4 — Installing Docker Engine"

if command -v docker &>/dev/null; then
  CURRENT_VERSION=$(docker --version 2>/dev/null)
  warn "Docker is already installed: $CURRENT_VERSION"
  read -p "Reinstall Docker? (y/n): " REINSTALL_DOCKER

  if [ "$REINSTALL_DOCKER" != "y" ]; then
    log "Skipping Docker installation."
    SKIP_DOCKER=true
  else
    SKIP_DOCKER=false
  fi
else
  SKIP_DOCKER=false
fi

if [ "$SKIP_DOCKER" = false ]; then
  echo "Downloading and installing Docker..."
  echo "This may take a few minutes."
  echo ""
  curl -fsSL https://get.docker.com | bash
  echo ""
  log "Docker Engine installed: $(docker --version)"
fi

# =============================================================================
# INSTALL DOCKER COMPOSE PLUGIN
# =============================================================================
section "Step 3/4 — Installing Docker Compose Plugin"

if docker compose version &>/dev/null; then
  CURRENT_COMPOSE=$(docker compose version 2>/dev/null)
  warn "Docker Compose is already installed: $CURRENT_COMPOSE"
  read -p "Reinstall Docker Compose plugin? (y/n): " REINSTALL_COMPOSE

  if [ "$REINSTALL_COMPOSE" != "y" ]; then
    log "Skipping Docker Compose installation."
    SKIP_COMPOSE=true
  else
    SKIP_COMPOSE=false
  fi
else
  SKIP_COMPOSE=false
fi

if [ "$SKIP_COMPOSE" = false ]; then
  echo "Installing Docker Compose plugin..."
  apt install -y docker-compose-plugin
  log "Docker Compose installed: $(docker compose version)"
fi

# Add user to docker group
if groups "$DOCKER_USER" 2>/dev/null | grep -q '\bdocker\b'; then
  log "User '$DOCKER_USER' is already in the docker group."
else
  usermod -aG docker "$DOCKER_USER"
  log "User '$DOCKER_USER' added to docker group."
fi

# =============================================================================
# HARDEN DOCKER DAEMON
# =============================================================================
section "Step 4/4 — Hardening Docker Daemon"

DAEMON_CONFIG="/etc/docker/daemon.json"

if [ -f "$DAEMON_CONFIG" ]; then
  warn "Docker daemon config already exists at $DAEMON_CONFIG."
  read -p "Overwrite with hardened config? (y/n): " RECONFIG_DAEMON
else
  RECONFIG_DAEMON="y"
fi

if [ "${RECONFIG_DAEMON:-y}" = "y" ]; then
  mkdir -p /etc/docker
  cat > "$DAEMON_CONFIG" << EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "no-new-privileges": true,
  "dns": ["8.8.8.8", "1.1.1.1"]
}
EOF

  log "Docker daemon hardened."
  log "  Log rotation: 10MB x 3 files"
  log "  No new privileges: ENABLED"
  log "  DNS servers: 8.8.8.8, 1.1.1.1"
else
  log "Skipping daemon configuration."
fi

# Enable and restart Docker
systemctl enable docker > /dev/null 2>&1
systemctl restart docker
log "Docker service enabled and running."

# Verify DNS works from inside a container
docker run --rm alpine nslookup google.com > /dev/null 2>&1 \
  && log "Docker DNS is working." \
  || warn "Docker DNS may not be working — check /etc/docker/daemon.json"

# =============================================================================
# VERIFY INSTALLATION
# =============================================================================
echo ""
echo "Verifying installation..."
echo ""

DOCKER_VER=$(docker --version 2>/dev/null || echo "NOT INSTALLED")
COMPOSE_VER=$(docker compose version 2>/dev/null || echo "NOT INSTALLED")
DOCKER_STATUS=$(systemctl is-active docker 2>/dev/null || echo "inactive")

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  DOCKER INSTALLATION COMPLETE${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Docker Engine  : $DOCKER_VER"
echo "  Docker Compose : $COMPOSE_VER"
echo "  Docker Service : $DOCKER_STATUS"
echo "  Docker User    : $DOCKER_USER"
echo ""
echo "  WHAT WAS CONFIGURED"
echo "  ───────────────────────────────────────────────"
echo "  [OK] Docker Engine installed"
echo "  [OK] Docker Compose plugin installed"
echo "  [OK] User '$DOCKER_USER' added to docker group"
echo "  [OK] Docker daemon hardened (log rotation, no-new-privileges)"
echo ""
echo "  NEXT STEPS"
echo "  ───────────────────────────────────────────────"
echo "  1. Log out and back in for docker group to take effect"
echo "  2. Test with: docker run hello-world"
echo "  3. Run: sudo bash 03-nginx-setup.sh"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
warn "You must log out and back in for the docker group change to take effect."
