# VPS Scripts

A collection of Bash scripts that let you deploy and manage Dockerized web apps on any Linux VPS with the ease of a platform like Vercel. No DevOps experience required — just run the scripts in order and follow the prompts.

Works on **real VPS providers** (DigitalOcean, Hetzner, Linode, etc.) and **local VirtualBox VMs** for testing.

---

## Prerequisites

- A fresh **Ubuntu 24.04 LTS** server (other Ubuntu versions may work)
- **Root access** (SSH in as root, or a user with `sudo`)
- Your app in a **git repository** with a `docker-compose.yml` or `Dockerfile`

---

## Quick Start

SSH into your server as root and run these scripts in order:

```bash
# 1. Harden the server (security)
sudo bash 01-vps-harden.sh

# 2. Install Docker
sudo bash 02-docker-install.sh

# 3. Set up Nginx + SSL
sudo bash 03-nginx-setup.sh

# 4. Deploy your app
sudo bash 04-deploy-app.sh

# 5. Install admin tools (optional but recommended)
sudo bash 06-admin-tools.sh

# 6. Run a security audit (optional)
sudo bash 07-security-check.sh
```

That's it. Your app is live.

---

## Script Reference

| # | Script | Purpose | Dependencies |
|---|--------|---------|-------------|
| 01 | `01-vps-harden.sh` | Lock down the server (SSH, firewall, intrusion detection) | None — run first |
| 02 | `02-docker-install.sh` | Install Docker + Compose | None (recommends 01) |
| 03 | `03-nginx-setup.sh` | Install Nginx + Certbot with secure defaults | None (run before 04) |
| 04 | `04-deploy-app.sh` | Deploy an app from a git repo | Requires 02 + 03 |
| 05 | `05-update-app.sh` | Update a deployed app (code or env vars) | Requires a deployed app |
| 06 | `06-admin-tools.sh` | Install admin utility commands | Recommends 01 + 02 |
| 07 | `07-security-check.sh` | Full security audit of the server | None (best after 01-06) |

All scripts are:
- **Interactive** — they prompt you for everything, no flags to memorize
- **Safe to re-run** — they detect what's already done and ask before overwriting
- **Standalone** — each script works on its own, no dependencies between files
- **Informative** — they tell you exactly what's happening at every step

---

## Detailed Script Guide

### 01-vps-harden.sh — Server Hardening

Secures a fresh Ubuntu server with production-grade security.

**You'll be asked for:**
- A deploy username (e.g. `deploy`)
- A password for that user (minimum 12 characters)
- SSH port (default 22, or a custom port like 2222)
- Server timezone (default UTC)

**What it configures:**
- Creates a deploy user with sudo access
- Hardens SSH (disables root login, strong ciphers, custom port, login limits)
- UFW firewall (allows only SSH, HTTP, HTTPS)
- Fail2ban intrusion detection (bans IPs after 3 failed SSH attempts for 72 hours)
- Automatic security updates (daily)
- Kernel network hardening (SYN flood protection, ICMP filtering, reverse path filtering)
- Password policy (minimum 12 characters, 3 character classes)
- Logwatch daily security reports

**After running:** Log out and SSH back in as your deploy user on the port you chose.

---

### 02-docker-install.sh — Docker Installation

Installs Docker Engine and Docker Compose plugin.

**You'll be asked for:**
- Which user should run Docker (your deploy user)

**What it configures:**
- Docker Engine (latest)
- Docker Compose plugin
- Adds your user to the `docker` group
- Hardens the Docker daemon (log rotation: 10MB x 3 files, no-new-privileges)

**After running:** Log out and back in for the docker group to take effect.

---

### 03-nginx-setup.sh — Nginx + Certbot

Installs Nginx as a reverse proxy with SSL support.

**What it configures:**
- Nginx with version hidden (`server_tokens off`)
- Security headers snippet (X-Frame-Options, Content-Type-Options, Referrer-Policy, Permissions-Policy, CSP)
- Proxy parameters snippet (WebSocket support, real IP forwarding, timeouts)
- Certbot for free SSL certificates
- Removes the default Nginx site

These snippets are reused automatically when you deploy apps.

---

### 04-deploy-app.sh — App Deployment

Deploys any Dockerized app to your server. Supports multiple apps on the same VPS.

**Three ways to provide your app:**

| Option | Best for |
|--------|----------|
| **1. Git repository** | Apps hosted on GitHub/GitLab. Clones the repo, supports private repos with access tokens. |
| **2. Paste docker-compose.yml** | Quick deployments. Paste your compose file contents directly — great for Docker Hub images or simple setups. |
| **3. Local folder** | Apps already on the server. Point to a folder with your docker-compose.yml and/or Dockerfiles, and it copies them into the managed apps directory. |

**You'll be asked for:**
- App name (e.g. `myapp`)
- App source (git repo, paste compose, or local folder)
- Port your app listens on (e.g. 3000, 8000, 8080)
- Environment variables (reads from `.env.example` if present, or manual entry)
- Domain name (optional — can use server IP instead)
- Whether to set up SSL (if you have a domain)

**What it does:**
- Gets your app source (clone, paste, or copy)
- Detects `docker-compose.yml` or `Dockerfile` automatically
- Generates a `docker-compose.yml` from Dockerfile if needed
- Prompts for each `.env.example` variable so you can fill in values
- Sets up Nginx reverse proxy with rate limiting and security headers
- Configures SSL via Certbot (with DNS verification dry-run)
- Saves deployment metadata for the update script
- Auto-detects VirtualBox and offers local test mode

**Your app lives at:** `/home/<deploy-user>/apps/<app-name>/`

---

### 05-update-app.sh — App Updates

Updates a deployed app's code, environment variables, or both. Automatically backs up everything before making changes and can roll back if something goes wrong.

**You'll be asked for:**
- Which app to update (shows a list of deployed apps)
- What to update: code, env vars, or both

**For code updates (depends on how you deployed):**
- **Git repo** — pulls latest code from your branch
- **Paste compose** — asks you to paste an updated docker-compose.yml
- **Local folder** — asks for the folder path to copy updated files from
- Rebuilds Docker containers after updating
- If the app fails to start → shows logs and offers to roll back

**For env updates:**
- Shows current variables (sensitive values are masked)
- Edit individual variables by number
- Add new variables

**Backups are saved at:** `/home/<deploy-user>/apps/<app-name>/.backups/<timestamp>/`

Each backup includes: `.env`, `docker-compose.yml`, deployment metadata, git commit hash, and Docker images.

---

### 06-admin-tools.sh — Admin Utilities

Installs helpful commands to `/usr/local/bin/` so they're available system-wide.

| Command | Usage | Purpose |
|---------|-------|---------|
| `vps-status` | `vps-status` | Server health dashboard (CPU, memory, disk, containers, firewall, banned IPs) |
| `vps-open-port` | `vps-open-port 8080` | Open a firewall port |
| `vps-close-port` | `vps-close-port 8080` | Close a firewall port |
| `vps-add-user` | `sudo vps-add-user john` | Add a system user (optional sudo, SSH, Docker access) |
| `vps-list-apps` | `vps-list-apps` | List all deployed apps with status, domain, port, and commit |
| `vps-logs` | `vps-logs myapp` | Tail Docker logs for an app (live, last 100 lines) |
| `vps-restart` | `vps-restart myapp` | Restart an app's containers |

---

### 07-security-check.sh — Security Audit

Runs a comprehensive security audit of your server and reports findings as PASS, WARN, or FAIL.

**Checks performed:**
1. **Package Security** — available updates, security patches, reboot required
2. **Docker Security** — daemon hardening, containers running as root, image freshness
3. **Network Security** — open ports, firewall status, fail2ban, services on 0.0.0.0
4. **SSH Security** — root login, password auth, port, AllowUsers, key permissions
5. **File Permissions** — .env files, SSH keys, world-writable files, Docker socket

Offers to install security updates if any are found.

---

## Testing on VirtualBox

You can test all scripts locally on a VirtualBox VM before deploying to a real VPS.

### VirtualBox Setup

1. Create an Ubuntu 24.04 VM in VirtualBox
2. Use **NAT** networking (the default)
3. Set up **port forwarding** in VirtualBox:

   **Settings > Network > Adapter 1 > Advanced > Port Forwarding**

   | Name  | Protocol | Host IP   | Host Port | Guest IP  | Guest Port |
   |-------|----------|-----------|-----------|-----------|------------|
   | SSH   | TCP      |           | 2222      |           | 22         |
   | HTTP  | TCP      |           | 8080      |           | 80         |
   | HTTPS | TCP      |           | 8443      |           | 443        |

4. SSH into the VM from your host: `ssh user@localhost -p 2222`

### Local Test Mode

When you run `04-deploy-app.sh` on a VirtualBox VM, it **automatically detects VirtualBox** and asks:

```
[!!] VirtualBox detected.
Run in local test mode? (y/n):
```

If you say **yes**, the script:
- Binds nginx to `0.0.0.0:80` (so traffic from port forwarding reaches it)
- Sets `server_name` to `localhost`
- Binds Docker ports to `0.0.0.0` instead of `127.0.0.1`
- Skips SSL/certbot (not possible on localhost)

After deployment, access your app from the host machine at: **http://localhost:8080**

### What works the same

Everything else works identically on VirtualBox and a real VPS:
- Server hardening (01)
- Docker installation (02)
- Nginx setup (03)
- App updates and rollbacks (05)
- Admin tools (06)
- Security audit (07)

---

## Directory Structure

After running all scripts and deploying apps, your server looks like this:

```
/home/<deploy-user>/
  apps/
    myapp1/
      .deploy-info          # Deployment metadata (used by update script)
      .backups/             # Timestamped backups for rollback
        20260316-143000/
          .env
          docker-compose.yml
          .deploy-info
          .git-commit
          images.tar.gz
      .env                  # Environment variables
      docker-compose.yml    # Docker config
      ...                   # App source code
    myapp2/
      ...

/etc/nginx/
  sites-available/
    myapp1                  # Nginx config per app
    myapp2
  snippets/
    security-headers.conf   # Shared security headers
    proxy-params.conf       # Shared proxy settings

/usr/local/bin/
  vps-status               # Admin commands
  vps-open-port
  vps-close-port
  vps-add-user
  vps-list-apps
  vps-logs
  vps-restart
```

---

## Troubleshooting

### I'm locked out of SSH

If you changed the SSH port and can't connect:
- Connect via your VPS provider's web console (DigitalOcean, Hetzner, etc. all have one)
- Edit `/etc/ssh/sshd_config.d/99-hardened.conf` and fix the port
- Run `systemctl restart ssh`

### My app won't start

```bash
# Check container logs
cd ~/apps/myapp && docker compose logs

# Check if containers are running
docker compose ps

# Check if the port is already in use
sudo ss -tlnp | grep <port>

# Restart the app
docker compose down && docker compose up -d --build
```

### SSL certificate won't install

- Make sure your domain's DNS A record points to your server's IP
- DNS changes can take up to 48 hours to propagate (usually 5-30 minutes)
- Run manually: `sudo certbot --nginx -d yourdomain.com`
- Check with: `dig yourdomain.com` to verify DNS

### I need to roll back an update

Run `sudo bash 05-update-app.sh` — if the app fails after update, it will automatically offer to roll back. Or manually:

```bash
cd ~/apps/myapp
# See available backups
ls .backups/

# Restore a specific backup's .env
cp .backups/20260316-143000/.env .env

# Restart
docker compose down && docker compose up -d --build
```

### How do I deploy a second app?

Just run `sudo bash 04-deploy-app.sh` again. Each app gets its own directory, Nginx config, and SSL certificate.

### How do I check server security?

Run `sudo bash 07-security-check.sh` for a full audit, or use `vps-status` for a quick health check.

---

## License

MIT
