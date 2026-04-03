# nginx-manager

A single-file, interactive Nginx management tool. Runs on a TUI (Terminal User Interface) and handles all operations through menus.

Supports both Turkish and English.

## Supported Systems

- Ubuntu / Debian / Linux Mint / Pop!_OS
- RHEL / CentOS / AlmaLinux / Rocky / Fedora
- Arch Linux / Manjaro / EndeavourOS
- Alpine Linux
- macOS (Homebrew)

The operating system is detected automatically. If detection fails, a manual selection menu is presented.

## Modules

### 1. Config Management

Site listing, enabling, disabling, and creating new virtual servers. Includes a framework-based profile/template system:

- **Static SPA:** React, Angular, Vue.js, Svelte, classic HTML
- **PHP:** WordPress, Laravel, Symfony, Drupal, general PHP-FPM
- **Node.js:** Next.js, Nuxt, Remix, Express/Fastify, SvelteKit, Astro
- **Python:** Django, Flask, FastAPI, general WSGI
- **Other:** Go, Rust, Ruby on Rails, Java/Spring Boot, .NET/ASP.NET Core

Also supports config editing (via EDITOR) and diff comparison between two configs.

### 2. SSL Certificate

Obtain, renew, and check expiry dates of certificates via Let's Encrypt (Certbot), with automatic renewal cron setup. Additionally:

- Self-signed certificate generation (for development environments)
- Cloudflare Origin CA certificate setup

### 3. Log Analysis

- Live log streaming (tail -f)
- Error listing (4xx/5xx)
- Top requesting IPs (with bar chart)
- HTTP status code distribution (colored bar chart)
- Most requested URLs
- Bandwidth report
- Date range filtering
- Export as CSV and JSON

### 4. Health Check and Service

Nginx status check, service start/stop/restart/reload, port listening check, and process info. Single or bulk URL accessibility testing is available. Automatic health check cron setup is supported.

### 5. Backup / Restore

Timestamped archival of config files, restore from backup (an automatic backup is taken before restore), backup listing, and cleanup of old backups.

### 6. Security Scan

Performs a full security scan across 10 checks and provides a score:

- server_tokens, security headers (X-Frame-Options, X-Content-Type-Options, CSP, etc.)
- SSL/TLS protocol check
- Directory listing (autoindex) check
- Sensitive file access check (.git, .env, wp-config.php, etc.)

Live URL header checking and SSL/TLS configuration analysis are also available.

### 7. Reverse Proxy

- Standard reverse proxy creation
- WebSocket proxy (upgrade header support)
- Load balancer (round-robin, least_conn, ip_hash)
- Listing existing proxy configs

### 8. Rate Limit / IP Blocking

- Rate limit rule creation (zone, rate, burst)
- IP blocking and unblocking
- Blocked IP list
- GeoIP country blocking template

### 9. Nginx Install / Remove

Installs Nginx directly if not already installed. If installed, offers reinstall or removal. Auto-start (systemctl enable) is configured automatically.

## Installation

```bash
git clone <repo-url>
cd nginx-manager
chmod +x manager.sh
```

## Usage

### Interactive Mode

```bash
sudo ./manager.sh
```

Starts with the Turkish interface by default. For English:

```bash
sudo ./manager.sh --lang en
```

Or via environment variable:

```bash
export NGINX_MGR_LANG=en
sudo ./manager.sh
```

### Command Line Mode

Run a single operation without entering the interactive menu:

```
./manager.sh --health            Nginx health check
./manager.sh --test              Config test (nginx -t)
./manager.sh --reload            Reload config
./manager.sh --restart           Restart Nginx
./manager.sh --status            Service status
./manager.sh --backup            Backup config
./manager.sh --ssl-check         SSL expiry check
./manager.sh --security-scan     Security scan
./manager.sh --list-sites        List sites
./manager.sh --block-ip IP       Block IP
./manager.sh --unblock-ip IP     Unblock IP
./manager.sh --export csv|json   Export log
./manager.sh --install           Install Nginx
./manager.sh --lang CODE         Language (en/tr)
./manager.sh --help              Help
```

CLI commands can be combined with `--lang`:

```bash
./manager.sh --lang en --ssl-check
```

## Requirements

- Bash 4.0+ (for associative array support)
- Root/sudo privileges (for most operations)
- Standard Unix tools: awk, sed, grep, curl, openssl, tar

Certbot and Nginx can be installed from within the script if not already present.

## Language Support

The script supports Turkish (default) and English. All user-facing strings are managed through an internal translation system. Language can be set in three ways:

1. CLI argument: `--lang en`
2. Environment variable: `NGINX_MGR_LANG=en`
3. Default: Turkish