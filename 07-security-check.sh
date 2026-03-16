#!/bin/bash

# =============================================================================
# 07-security-check.sh
# Full VPS Security Audit
# =============================================================================
#
# PURPOSE:
#   Run a comprehensive security audit of your server. Checks packages,
#   Docker, network, SSH, and file permissions. Reports findings as
#   PASS, WARN, or FAIL with recommendations for fixing issues.
#   Offers to install security updates if any are found.
#
# DEPENDENCIES:
#   None — works best after running 01-06 scripts.
#
# USAGE:
#   sudo bash 07-security-check.sh
#
# SAFE TO RE-RUN:
#   Yes — this is a read-only audit (except for optional package updates).
#
# =============================================================================

set -euo pipefail

# --- Colors & Logging (self-contained) ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!!]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $1${NC}\n${BLUE}══════════════════════════════════════${NC}\n"; }

pass()    { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()    { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); RECOMMENDATIONS+=("$1"); }
audit_warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARN_COUNT=$((WARN_COUNT + 1)); RECOMMENDATIONS+=("$1"); }

# Counters
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
RECOMMENDATIONS=()

# Detect deploy user
DEPLOY_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 && $6 ~ /^\/home/ {print $1; exit}' /etc/passwd 2>/dev/null || true)
DEPLOY_HOME="/home/${DEPLOY_USER:-deploy}"
APPS_DIR="$DEPLOY_HOME/apps"

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

[ "$EUID" -ne 0 ] && error "This script must be run as root. Use: sudo bash 07-security-check.sh"

# =============================================================================
# WELCOME BANNER
# =============================================================================
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  VPS SECURITY AUDIT${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  This script will check:"
echo "    1. Package security & available updates"
echo "    2. Docker security"
echo "    3. Network security (ports, firewall, fail2ban)"
echo "    4. SSH configuration"
echo "    5. File permissions"
echo ""
echo "  Each check reports: PASS, WARN, or FAIL"
echo "  A summary with recommendations is shown at the end."
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

read -p "Run security audit? (y/n): " START_CONFIRM
[ "$START_CONFIRM" != "y" ] && echo "Aborted." && exit 0

# =============================================================================
# STEP 1: PACKAGE SECURITY
# =============================================================================
section "Step 1/5 — Package Security"

echo "Refreshing package lists..."
apt update -qq 2>/dev/null

# Check for upgradable packages
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || true)

if [ "$UPGRADABLE" -eq 0 ]; then
  pass "All packages are up to date."
else
  fail "$UPGRADABLE package(s) have available updates."
  echo ""
  echo "  Upgradable packages:"
  apt list --upgradable 2>/dev/null | grep "upgradable" | sed 's/^/    /'
  echo ""

  read -p "  Install all available updates now? (y/n): " INSTALL_UPDATES
  if [ "$INSTALL_UPDATES" = "y" ]; then
    echo ""
    echo "  Installing updates..."
    export DEBIAN_FRONTEND=noninteractive
    apt upgrade -y 2>&1 | tail -5 | sed 's/^/    /'
    log "Updates installed."
    # Recount
    FAIL_COUNT=$((FAIL_COUNT - 1))
    PASS_COUNT=$((PASS_COUNT + 1))
    # Remove the recommendation
    RECOMMENDATIONS=("${RECOMMENDATIONS[@]/$UPGRADABLE package(s) have available updates./}")
  fi
fi

# Check for security-specific updates
SECURITY_UPDATES=$(apt list --upgradable 2>/dev/null | grep -i "\-security" | wc -l || true)
if [ "$SECURITY_UPDATES" -gt 0 ]; then
  fail "$SECURITY_UPDATES security-specific update(s) pending."
else
  pass "No pending security-specific updates."
fi

# Check unattended-upgrades
if systemctl is-active unattended-upgrades &>/dev/null; then
  pass "Automatic security updates are enabled."
else
  fail "Automatic security updates are NOT enabled. Run 01-vps-harden.sh or enable unattended-upgrades."
fi

# Check if reboot required
if [ -f /var/run/reboot-required ]; then
  audit_warn "A reboot is required to apply kernel updates. Run: sudo reboot"
else
  pass "No reboot required."
fi

# =============================================================================
# STEP 2: DOCKER SECURITY
# =============================================================================
section "Step 2/5 — Docker Security"

if ! command -v docker &>/dev/null; then
  echo "  Docker is not installed. Skipping Docker checks."
else
  # Docker daemon running?
  if systemctl is-active docker &>/dev/null; then
    pass "Docker daemon is running."
  else
    fail "Docker daemon is NOT running."
  fi

  # Daemon hardening
  DAEMON_JSON="/etc/docker/daemon.json"
  if [ -f "$DAEMON_JSON" ]; then
    if grep -q '"no-new-privileges"' "$DAEMON_JSON"; then
      pass "Docker no-new-privileges is enabled."
    else
      fail "Docker no-new-privileges is NOT set in $DAEMON_JSON."
    fi

    if grep -q '"max-size"' "$DAEMON_JSON"; then
      pass "Docker log rotation is configured."
    else
      audit_warn "Docker log rotation is NOT configured. Logs may grow unbounded."
    fi
  else
    fail "Docker daemon config ($DAEMON_JSON) does not exist. Run 02-docker-install.sh."
  fi

  # Containers running as root
  ROOT_CONTAINERS=0
  while IFS= read -r container_id; do
    [ -z "$container_id" ] && continue
    CONTAINER_USER=$(docker inspect --format '{{.Config.User}}' "$container_id" 2>/dev/null || true)
    if [ -z "$CONTAINER_USER" ] || [ "$CONTAINER_USER" = "root" ] || [ "$CONTAINER_USER" = "0" ]; then
      CONTAINER_NAME=$(docker inspect --format '{{.Name}}' "$container_id" 2>/dev/null | sed 's/^\///')
      ROOT_CONTAINERS=$((ROOT_CONTAINERS + 1))
    fi
  done < <(docker ps -q 2>/dev/null)

  if [ "$ROOT_CONTAINERS" -gt 0 ]; then
    audit_warn "$ROOT_CONTAINERS container(s) running as root. Consider using a non-root user in your Dockerfile."
    # List them
    docker ps --format "    {{.Names}}" 2>/dev/null | while read -r name; do
      CID=$(docker ps -q --filter "name=${name##* }" 2>/dev/null | head -1)
      [ -z "$CID" ] && continue
      CUSER=$(docker inspect --format '{{.Config.User}}' "$CID" 2>/dev/null || echo "root")
      [ -z "$CUSER" ] && CUSER="root"
      echo "    $name (user: $CUSER)"
    done
  else
    RUNNING=$(docker ps -q 2>/dev/null | wc -l)
    if [ "$RUNNING" -gt 0 ]; then
      pass "No containers running as root ($RUNNING container(s) checked)."
    else
      echo "  No running containers to check."
    fi
  fi

  # Check deployed app images for updates
  if [ -d "$APPS_DIR" ]; then
    for app_dir in "$APPS_DIR"/*/; do
      [ ! -f "${app_dir}docker-compose.yml" ] && [ ! -f "${app_dir}docker-compose.yaml" ] && continue
      APP=$(basename "$app_dir")
      # Check if containers are running
      if cd "$app_dir" && docker compose ps -q 2>/dev/null | head -1 | grep -q .; then
        # Check image creation date
        IMAGE_ID=$(docker compose images -q 2>/dev/null | head -1)
        if [ -n "$IMAGE_ID" ]; then
          CREATED=$(docker inspect --format '{{.Created}}' "$IMAGE_ID" 2>/dev/null | cut -d'T' -f1)
          DAYS_OLD=$(( ( $(date +%s) - $(date -d "$CREATED" +%s 2>/dev/null || echo "0") ) / 86400 )) 2>/dev/null || DAYS_OLD=0
          if [ "$DAYS_OLD" -gt 30 ]; then
            audit_warn "App '$APP' image is $DAYS_OLD days old. Consider rebuilding."
          else
            pass "App '$APP' image is recent ($DAYS_OLD days old)."
          fi
        fi
      fi
    done
  fi

  # Docker socket permissions
  if [ -S /var/run/docker.sock ]; then
    SOCK_PERMS=$(stat -c %a /var/run/docker.sock 2>/dev/null || true)
    if [ "$SOCK_PERMS" = "660" ] || [ "$SOCK_PERMS" = "600" ]; then
      pass "Docker socket permissions are restrictive ($SOCK_PERMS)."
    else
      audit_warn "Docker socket permissions are $SOCK_PERMS (expected 660 or 600)."
    fi
  fi
fi

# =============================================================================
# STEP 3: NETWORK SECURITY
# =============================================================================
section "Step 3/5 — Network Security"

# UFW status
if command -v ufw &>/dev/null; then
  if ufw status | grep -q "Status: active"; then
    pass "UFW firewall is active."

    # Check for overly permissive rules
    ALLOW_ANY=$(ufw status | grep -c "ALLOW.*Anywhere" || true)
    if [ "$ALLOW_ANY" -gt 5 ]; then
      audit_warn "UFW has $ALLOW_ANY 'ALLOW Anywhere' rules. Review if all are necessary."
    fi
  else
    fail "UFW firewall is NOT active. Run 01-vps-harden.sh or enable with: sudo ufw enable"
  fi
else
  fail "UFW is not installed. Run 01-vps-harden.sh."
fi

# Fail2ban
if command -v fail2ban-client &>/dev/null; then
  if systemctl is-active fail2ban &>/dev/null; then
    pass "Fail2ban is running."

    # Check if sshd jail is active
    if fail2ban-client status sshd &>/dev/null; then
      BANNED=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
      pass "Fail2ban SSH jail is active ($BANNED IPs currently banned)."
    else
      audit_warn "Fail2ban SSH jail is not active."
    fi
  else
    fail "Fail2ban is NOT running. Enable with: sudo systemctl enable --now fail2ban"
  fi
else
  fail "Fail2ban is not installed. Run 01-vps-harden.sh."
fi

# Open ports
echo ""
echo "  Checking open ports..."
echo ""

# Expected ports: SSH (22 or custom), 80, 443
LISTENING_PORTS=$(ss -tlnp 2>/dev/null | grep LISTEN | awk '{print $4}' | grep -oP '\d+$' | sort -un)
EXPECTED_PORTS="80 443"

# Get SSH port from config
SSH_PORT=$(grep "^Port " /etc/ssh/sshd_config.d/99-hardened.conf 2>/dev/null | awk '{print $2}')
SSH_PORT=${SSH_PORT:-22}
EXPECTED_PORTS="$SSH_PORT $EXPECTED_PORTS"

for port in $LISTENING_PORTS; do
  PORT_PROCESS=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 | grep -oP 'users:\(\("\K[^"]+' || echo "unknown")
  if echo "$EXPECTED_PORTS" | grep -qw "$port"; then
    pass "Port $port ($PORT_PROCESS) — expected."
  else
    # Docker internal ports are okay if bound to 127.0.0.1
    BIND_ADDR=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 | awk '{print $4}')
    if echo "$BIND_ADDR" | grep -q "127.0.0.1"; then
      pass "Port $port ($PORT_PROCESS) — bound to localhost only."
    else
      audit_warn "Port $port ($PORT_PROCESS) is open and not in expected list. Verify this is intentional."
    fi
  fi
done

# Check for services on 0.0.0.0 that should be on 127.0.0.1
WILDCARD_SERVICES=$(ss -tlnp 2>/dev/null | grep "0.0.0.0:" | grep -v ":${SSH_PORT}\b" | grep -v ":80\b" | grep -v ":443\b" || true)
if [ -n "$WILDCARD_SERVICES" ]; then
  audit_warn "Some services are listening on 0.0.0.0 (all interfaces) instead of 127.0.0.1:"
  echo "$WILDCARD_SERVICES" | sed 's/^/    /'
fi

# =============================================================================
# STEP 4: SSH SECURITY
# =============================================================================
section "Step 4/5 — SSH Security"

SSHD_HARDENED="/etc/ssh/sshd_config.d/99-hardened.conf"

if [ -f "$SSHD_HARDENED" ]; then
  pass "Hardened SSH config exists."

  # Root login
  if grep -q "^PermitRootLogin no" "$SSHD_HARDENED"; then
    pass "Root SSH login is disabled."
  else
    fail "Root SSH login is NOT disabled. Add 'PermitRootLogin no' to $SSHD_HARDENED."
  fi

  # AllowUsers
  if grep -q "^AllowUsers" "$SSHD_HARDENED"; then
    ALLOWED=$(grep "^AllowUsers" "$SSHD_HARDENED" | cut -d' ' -f2-)
    pass "SSH AllowUsers is set: $ALLOWED"
  else
    audit_warn "SSH AllowUsers is not set. Any system user can SSH in."
  fi

  # SSH port
  CURRENT_SSH_PORT=$(grep "^Port " "$SSHD_HARDENED" | awk '{print $2}')
  if [ "${CURRENT_SSH_PORT:-22}" = "22" ]; then
    audit_warn "SSH is on default port 22. A custom port adds a layer of obscurity."
  else
    pass "SSH is on non-default port $CURRENT_SSH_PORT."
  fi

  # Password authentication
  if grep -q "^PasswordAuthentication yes" "$SSHD_HARDENED"; then
    audit_warn "SSH password authentication is enabled. Consider switching to key-only auth for stronger security."
  elif grep -q "^PasswordAuthentication no" "$SSHD_HARDENED"; then
    pass "SSH password authentication is disabled (key-only)."
  else
    audit_warn "SSH password authentication setting not found in hardened config."
  fi

  # Max auth tries
  if grep -q "^MaxAuthTries" "$SSHD_HARDENED"; then
    MAX_TRIES=$(grep "^MaxAuthTries" "$SSHD_HARDENED" | awk '{print $2}')
    if [ "$MAX_TRIES" -le 5 ]; then
      pass "SSH MaxAuthTries is $MAX_TRIES."
    else
      audit_warn "SSH MaxAuthTries is $MAX_TRIES (should be 5 or less)."
    fi
  fi

  # X11 forwarding
  if grep -q "^X11Forwarding no" "$SSHD_HARDENED"; then
    pass "X11 forwarding is disabled."
  else
    audit_warn "X11 forwarding may be enabled. Disable it unless you need it."
  fi

else
  fail "Hardened SSH config not found at $SSHD_HARDENED. Run 01-vps-harden.sh."

  # Still check base sshd_config
  if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config 2>/dev/null; then
    pass "Root SSH login is disabled (in main config)."
  else
    fail "Root SSH login may be enabled."
  fi
fi

# Check authorized_keys permissions
if [ -n "$DEPLOY_USER" ] && [ -d "$DEPLOY_HOME/.ssh" ]; then
  SSH_DIR_PERMS=$(stat -c %a "$DEPLOY_HOME/.ssh" 2>/dev/null || true)
  if [ "$SSH_DIR_PERMS" = "700" ]; then
    pass "$DEPLOY_USER .ssh directory permissions are correct (700)."
  else
    fail "$DEPLOY_USER .ssh directory permissions are $SSH_DIR_PERMS (should be 700)."
  fi

  if [ -f "$DEPLOY_HOME/.ssh/authorized_keys" ]; then
    AK_PERMS=$(stat -c %a "$DEPLOY_HOME/.ssh/authorized_keys" 2>/dev/null || true)
    if [ "$AK_PERMS" = "600" ]; then
      pass "authorized_keys permissions are correct (600)."
    else
      fail "authorized_keys permissions are $AK_PERMS (should be 600)."
    fi
  fi
fi

# =============================================================================
# STEP 5: FILE PERMISSIONS
# =============================================================================
section "Step 5/5 — File Permissions"

# Check .env files
if [ -d "$APPS_DIR" ]; then
  ENV_FILES_CHECKED=0
  for env_file in "$APPS_DIR"/*/.env; do
    [ ! -f "$env_file" ] && continue
    ENV_FILES_CHECKED=$((ENV_FILES_CHECKED + 1))
    PERMS=$(stat -c %a "$env_file" 2>/dev/null || true)
    APP=$(basename "$(dirname "$env_file")")
    if [ "$PERMS" = "600" ]; then
      pass "App '$APP' .env permissions are correct (600)."
    else
      fail "App '$APP' .env permissions are $PERMS (should be 600). Fix: chmod 600 $env_file"
    fi
  done

  if [ "$ENV_FILES_CHECKED" -eq 0 ]; then
    echo "  No .env files found in deployed apps."
  fi

  # Check .deploy-info files
  for info_file in "$APPS_DIR"/*/.deploy-info; do
    [ ! -f "$info_file" ] && continue
    PERMS=$(stat -c %a "$info_file" 2>/dev/null || true)
    APP=$(basename "$(dirname "$info_file")")
    if [ "$PERMS" = "600" ]; then
      pass "App '$APP' .deploy-info permissions are correct (600)."
    else
      audit_warn "App '$APP' .deploy-info permissions are $PERMS (should be 600). Fix: chmod 600 $info_file"
    fi
  done

  # Check for world-writable files in app directories
  WORLD_WRITABLE=$(find "$APPS_DIR" -type f -perm -o+w 2>/dev/null | head -10)
  if [ -n "$WORLD_WRITABLE" ]; then
    fail "World-writable files found in apps directory:"
    echo "$WORLD_WRITABLE" | sed 's/^/    /'
  else
    pass "No world-writable files in apps directory."
  fi
else
  echo "  No apps directory found. Skipping app file checks."
fi

# Check /etc/ssh permissions
if [ -d /etc/ssh ]; then
  SSH_ETC_PERMS=$(stat -c %a /etc/ssh 2>/dev/null || true)
  if [ "$SSH_ETC_PERMS" = "755" ]; then
    pass "/etc/ssh directory permissions are correct (755)."
  else
    audit_warn "/etc/ssh directory permissions are $SSH_ETC_PERMS (expected 755)."
  fi

  # Check private keys
  for key_file in /etc/ssh/ssh_host_*_key; do
    [ ! -f "$key_file" ] && continue
    KEY_PERMS=$(stat -c %a "$key_file" 2>/dev/null || true)
    if [ "$KEY_PERMS" = "600" ]; then
      pass "$(basename "$key_file") permissions correct (600)."
    else
      fail "$(basename "$key_file") permissions are $KEY_PERMS (should be 600)."
    fi
  done
fi

# Check password policy
if [ -f /etc/security/pwquality.conf ]; then
  if grep -q "minlen" /etc/security/pwquality.conf; then
    MIN_LEN=$(grep "^minlen" /etc/security/pwquality.conf | awk -F= '{print $2}' | tr -d ' ')
    if [ "${MIN_LEN:-0}" -ge 12 ]; then
      pass "Password policy: minimum length is $MIN_LEN."
    else
      audit_warn "Password minimum length is $MIN_LEN (should be 12+)."
    fi
  fi
else
  audit_warn "Password quality config not found. Run 01-vps-harden.sh to enforce password policy."
fi

# =============================================================================
# SUMMARY
# =============================================================================
TOTAL=$((PASS_COUNT + WARN_COUNT + FAIL_COUNT))

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  SECURITY AUDIT RESULTS${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Total checks : $TOTAL"
echo -e "  ${GREEN}PASS${NC}         : $PASS_COUNT"
echo -e "  ${YELLOW}WARN${NC}         : $WARN_COUNT"
echo -e "  ${RED}FAIL${NC}         : $FAIL_COUNT"
echo ""

# Score
if [ "$TOTAL" -gt 0 ]; then
  SCORE=$(( (PASS_COUNT * 100) / TOTAL ))
  if [ "$SCORE" -ge 90 ]; then
    echo -e "  Security score: ${GREEN}${SCORE}% — Excellent${NC}"
  elif [ "$SCORE" -ge 70 ]; then
    echo -e "  Security score: ${YELLOW}${SCORE}% — Good, but has warnings${NC}"
  elif [ "$SCORE" -ge 50 ]; then
    echo -e "  Security score: ${YELLOW}${SCORE}% — Needs attention${NC}"
  else
    echo -e "  Security score: ${RED}${SCORE}% — Critical issues found${NC}"
  fi
fi

# Recommendations
if [ ${#RECOMMENDATIONS[@]} -gt 0 ]; then
  echo ""
  echo "  RECOMMENDATIONS"
  echo "  ───────────────────────────────────────────────"
  SEEN=()
  for rec in "${RECOMMENDATIONS[@]}"; do
    [ -z "$rec" ] && continue
    # Deduplicate
    SKIP=false
    for s in "${SEEN[@]+"${SEEN[@]}"}"; do
      [ "$s" = "$rec" ] && SKIP=true && break
    done
    [ "$SKIP" = true ] && continue
    SEEN+=("$rec")
    echo -e "  - $rec"
  done
fi

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
  log "Your server passed all security checks."
elif [ "$FAIL_COUNT" -eq 0 ]; then
  warn "No critical issues, but $WARN_COUNT warning(s) to review."
else
  warn "$FAIL_COUNT critical issue(s) found. Review the recommendations above."
fi

echo ""
echo "  Run this audit regularly to keep your server secure."
echo "  Tip: Set up a cron job: sudo crontab -e"
echo "    0 6 * * 1 /path/to/07-security-check.sh > /var/log/security-audit.log 2>&1"
echo ""
