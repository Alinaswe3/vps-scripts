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

# 5. Install admin tools (recommended)
sudo bash 06-admin-tools.sh

# 6. Set up nginx reverse proxy for your app
sudo vps-nginx-config

# 7. Run a security audit (optional)
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
| 04 | `04-deploy-app.sh` | Deploy an app from a git repo | Requires 02 |
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
- Hardens the Docker daemon (log rotation: 10MB x 3 files, no-new-privileges, DNS: 8.8.8.8 + 1.1.1.1)
- Verifies DNS resolution works from inside a test container after setup

**After running:** Log out and back in for the docker group to take effect.

---

### 03-nginx-setup.sh — Nginx + Certbot

Installs Nginx as a reverse proxy with SSL support.

**What it configures:**
- Nginx with version hidden (`server_tokens off`)
- Security headers snippet (X-Frame-Options, Content-Type-Options, Referrer-Policy, Permissions-Policy, HSTS — CSP is left to each app)
- Proxy parameters snippet (WebSocket support, real IP forwarding, timeouts, response buffer sizing for large headers)
- Certbot for free SSL certificates
- Removes the default Nginx site

These snippets are reused automatically when you deploy apps.

**HSTS (`Strict-Transport-Security`)** is included in the security headers snippet with `max-age=31536000; includeSubDomains`. Certbot's `--redirect` flag strips the HTTP (port 80) block down to a bare 301 redirect, so this header ends up only in the HTTPS (443) server block where it is meaningful. Once a browser sees this header it will refuse plain HTTP connections for one year — only enable SSL once you are committed to running HTTPS permanently.

**Using Cloudflare DNS?** Set your A records to **DNS only (grey cloud)** before running `vps-nginx-config` with SSL. Certbot's HTTP-01 challenge requires traffic to reach your VPS directly on port 80. Once the certificate is installed you can re-enable the orange cloud (Cloudflare proxy) if you want, but note that Cloudflare will then terminate SSL at its edge and re-encrypt to your server — the certificate Certbot installed is still used for the Cloudflare→VPS leg.

---

### 04-deploy-app.sh — App Deployment

Deploys any Dockerized app to your server. Supports multiple apps on the same VPS.

**You'll be asked for:**
- App name (e.g. `myapp`)
- Git repository URL (HTTPS, supports private repos with access tokens)
- Branch to deploy (default: `main`)
- Which compose/Dockerfile to use (auto-detected from the repo)
- Environment variables (bulk paste your `.env` contents)
- Registry login if your compose file references private images (e.g. `ghcr.io`)

**What it does:**
- Clones your git repo
- Finds all `docker-compose.yml` / `Dockerfile` candidates and lets you pick
- Lets you paste your entire `.env` file in one go (CTRL+D to finish)
- Detects private registry images and handles `docker login`

**Compose file requirements:** Your production compose file must use `image:` for every service — do not include `build:` directives. The deploy script will offer to replace a `build:` with a registry image URL, but the cleanest approach is to maintain a separate `docker-compose.yml` (production, `image:` only) alongside your `docker-compose.dev.yml` (local, `build:` only). Services like `db`, `redis`, or `waha` that you don't build yourself should only have `image:` — never both `image:` and `build:` in the same service block.
- Pulls images and starts containers with `docker compose up`
- Saves deployment metadata for the update script

**Your app lives at:** `/home/<deploy-user>/apps/<app-name>/`

#### Setting up Nginx for your app

After deploying, run `sudo vps-nginx-config` to set up nginx reverse proxy. You'll choose between two routing methods:

| Method | Best for | How it works |
|--------|----------|-------------|
| **Domain** | Production | Each app gets a domain (e.g. `app1.example.com`). Nginx routes by hostname. All apps share port 80/443. Supports SSL. |
| **Port** | Testing / no domain | Each app gets a public port (e.g. 8080). Access via `http://SERVER_IP:8080`. No domain or DNS needed. |

**For multiple apps:** just run `sudo vps-nginx-config` once per app. Each app gets its own nginx config. To reset an app's config, run the command again — it detects the existing config and asks if you want to overwrite.

---

### 05-update-app.sh — App Updates

Updates a deployed app's code, environment variables, or both. Automatically backs up everything before making changes and can roll back if something goes wrong.

**You'll be asked for:**
- Which app to update (shows a list of deployed apps)
- What to update: code, env vars, or both

**For code updates:**
- Pulls latest code from your git branch
- Optionally change the Docker image tag (e.g. `latest` → `v2.0`)
- Rebuilds and restarts containers
- If the app fails to start → shows logs and offers to roll back

**For env updates:**
- Shows current variables (sensitive values are masked)
- Edit individual variables by number
- Add new variables
- Or paste a completely new `.env` file

**Backups are saved at:** `/home/<deploy-user>/apps/<app-name>/.backups/<timestamp>/`

Each backup includes: `.env`, compose file, deployment metadata, and running image list.

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
| `vps-nginx-config` | `sudo vps-nginx-config` | Create or reset nginx reverse proxy for an app (domain or port routing, SSL) |
| `vps-remove-app` | `sudo vps-remove-app` | Interactively remove a deployed app (stops containers, removes nginx config, deletes files, optionally revokes SSL) |
| `vps-cleanup` | `sudo vps-cleanup` | Free disk space (Docker cache, unused images, old backups, journal logs, APT cache) |

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
  vps-nginx-config
  vps-remove-app
  vps-cleanup
```

---

## Troubleshooting

### I'm locked out of SSH

If you changed the SSH port and can't connect:
- Connect via your VPS provider's web console (DigitalOcean, Hetzner, etc. all have one)
- Edit `/etc/ssh/sshd_config` and fix the `Port` line
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

### I'm getting 502 Bad Gateway on some routes

This usually means your app sends response headers that exceed nginx's default 4KB buffer — common with frameworks like SvelteKit or Next.js that include CSP nonces, `Link` preload headers for JS chunks, and session cookies. Re-run the nginx setup and regenerate your app's config:

```bash
sudo bash 03-nginx-setup.sh    # updates proxy-params.conf with larger buffers
sudo bash 06-admin-tools.sh    # updates vps-nginx-config
sudo vps-nginx-config           # regenerate your app's nginx config
```

### SSL certificate won't install

- Make sure your domain's DNS A record points to your server's IP
- DNS changes can take up to 48 hours to propagate (usually 5-30 minutes)
- Run manually: `sudo certbot --nginx -d yourdomain.com`
- Check with: `dig yourdomain.com` to verify DNS
- **Cloudflare users:** temporarily set the A record to **DNS only (grey cloud)** before running certbot. The HTTP-01 challenge requires port 80 traffic to reach your VPS directly. Cloudflare's proxy (orange cloud) intercepts it and causes the challenge to fail. You can re-enable the orange cloud after the certificate is installed.

### How do I force HTTPS and block plain HTTP?

Run `sudo vps-nginx-config`, select your app, choose **Domain** routing, and say **yes** to SSL. Certbot will install a certificate and automatically add a 301 redirect from HTTP → HTTPS. The security headers snippet also sets `Strict-Transport-Security` (HSTS) so browsers enforce HTTPS on future visits without waiting for the redirect. No manual nginx editing is required.

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

### My server is running out of disk space

Run `sudo vps-cleanup` for a guided cleanup. It shows a full storage overview and walks you through 7 cleanup steps:

1. Docker build cache
2. Dangling and unused images (never touches images used by running containers)
3. Stopped containers
4. Unused Docker networks
5. Old app backups (keeps last 5 per app)
6. System journal logs older than 7 days
7. APT package cache

Every step asks for confirmation — nothing is deleted automatically. Volumes, `.env` files, compose files, and running containers are never touched.

### How do I deploy a second app?

Just run `sudo bash 04-deploy-app.sh` again. Each app gets its own directory, Nginx config, and SSL certificate.

### How do I check server security?

Run `sudo bash 07-security-check.sh` for a full audit, or use `vps-status` for a quick health check.

---

## Tips

### Add Swap Space

Budget VPS plans (1-2GB RAM) often run out of memory during Docker image builds or when running multiple apps. The server either kills a container or the build fails silently. Adding swap gives the OS overflow space on disk so it doesn't run out of memory — it's slower than RAM but prevents crashes.

```bash
# Add 1GB swap (adjust size as needed: 1G, 2G, 4G)
sudo fallocate -l 1G /swap.img
sudo chmod 600 /swap.img
sudo mkswap /swap.img
sudo swapon /swap.img

# Make permanent across reboots
echo '/swap.img none swap sw 0 0' | sudo tee -a /etc/fstab

# Reduce swap aggressiveness — only use swap when RAM is 90%+ full
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
sudo sysctl vm.swappiness=10
```

**How much swap?** A good rule of thumb: match your RAM (1GB RAM → 1GB swap, 2GB RAM → 2GB swap). Servers with 4GB+ RAM rarely need more than 2GB swap.

Verify it's active with `free -h` — you should see your swap size in the output.

---

## License

MIT
