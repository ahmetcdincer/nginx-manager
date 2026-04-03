#!/usr/bin/env bash
# ============================================================
#  nginx-manager.sh — Nginx Otomasyon Aracı v1.0
#  Modüller: Config, SSL, Log Analizi, Health Check,
#            Backup/Restore, Güvenlik Taraması,
#            Reverse Proxy, Rate Limit / IP Engelleme
#  OS Desteği: Ubuntu/Debian, RHEL/CentOS/AlmaLinux, Arch,
#              Alpine, macOS (Homebrew)
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
WHITE='\033[1;37m'

BOX_WIDTH=52
INNER_WIDTH=$((BOX_WIDTH - 2))

OS_ID=""
OS_FAMILY=""
PKG_INSTALL=""
PKG_UPDATE=""
SERVICE_CMD=""
NGINX_SITES_AVAILABLE=""
NGINX_SITES_ENABLED=""
NGINX_LOG_DIR=""
NGINX_CONF=""
CERTBOT_PKG=""
LOG_FILE="/tmp/nginx-manager.log"
BACKUP_DIR="/var/backups/nginx-manager"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
CLI_MODE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANG_CODE="${NGINX_MGR_LANG:-tr}"
declare -A MSG

# ── i18n: Çeviri fonksiyonu ─────────────────────────────────
# Kullanım: t "key"  veya  t "key" "arg1" "arg2"
t() {
  local key="$1"; shift
  local tpl="${MSG[$key]:-$key}"
  if [[ $# -gt 0 ]]; then
    printf "$tpl" "$@"
  else
    echo "$tpl"
  fi
}

# ── i18n: Dil dosyalarını yükle ────────────────────────────────
init_lang() {
  local lang_file
  case "$LANG_CODE" in
    en|EN) lang_file="$SCRIPT_DIR/lang/en.sh" ;;
    *)     lang_file="$SCRIPT_DIR/lang/tr.sh" ;;
  esac
  if [[ -f "$lang_file" ]]; then
    source "$lang_file"
  else
    echo "Dil dosyası bulunamadı: $lang_file" >&2
    exit 1
  fi
  case "$LANG_CODE" in
    en|EN) load_lang_en ;;
    *)     load_lang_tr ;;
  esac
}

init_lang

draw_line() {
  local char="${1:-─}" width="${2:-$BOX_WIDTH}"
  local line=""
  for ((i=0; i<width; i++)); do line+="$char"; done
  echo "$line"
}

draw_top() {
  echo -e "${BLUE}╭$(draw_line '─' $INNER_WIDTH)╮${NC}"
}

draw_bottom() {
  echo -e "${BLUE}╰$(draw_line '─' $INNER_WIDTH)╯${NC}"
}

draw_separator() {
  echo -e "${BLUE}├$(draw_line '─' $INNER_WIDTH)┤${NC}"
}

draw_row() {
  local text="$1"
  local stripped
  stripped=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
  local len=${#stripped}
  local pad=$((INNER_WIDTH - len))
  if (( pad < 0 )); then pad=0; fi
  local spaces=""
  for ((i=0; i<pad; i++)); do spaces+=" "; done
  echo -e "${BLUE}│${NC}${text}${spaces}${BLUE}│${NC}"
}

draw_row_center() {
  local text="$1"
  local stripped
  stripped=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
  local len=${#stripped}
  local total_pad=$((INNER_WIDTH - len))
  local left_pad=$((total_pad / 2))
  local right_pad=$((total_pad - left_pad))
  if (( left_pad < 0 )); then left_pad=0; fi
  if (( right_pad < 0 )); then right_pad=0; fi
  local lspaces="" rspaces=""
  for ((i=0; i<left_pad; i++)); do lspaces+=" "; done
  for ((i=0; i<right_pad; i++)); do rspaces+=" "; done
  echo -e "${BLUE}│${NC}${lspaces}${text}${rspaces}${BLUE}│${NC}"
}

draw_empty() {
  draw_row ""
}

draw_title() {
  local title="$1"
  draw_top
  draw_row_center "${BOLD}${WHITE}$title${NC}"
  draw_bottom
}

draw_prompt() {
  echo ""
  echo -ne "  ${CYAN}>${NC} "
}

draw_footer() {
  echo ""
  echo -e "  ${DIM}$(t nav_back_quit)${NC}"
}

draw_main_footer() {
  echo ""
  echo -e "  ${DIM}$(t nav_quit_only)${NC}"
}

pause_prompt() {
  echo ""
  echo -ne "  ${DIM}$(t press_enter)${NC} "
  read -r _
}

draw_bar() {
  local value=$1 max=$2 width=${3:-30}
  (( max == 0 )) && max=1
  local filled=$((value * width / max))
  (( filled > width )) && filled=$width
  local empty=$((width - filled))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done
  echo "$bar"
}

# Mesaj Fonksiyonları
log()  { echo -e "  ${GREEN}  ✓${NC} $1"; echo "[$TIMESTAMP] OK: $1"    >> "$LOG_FILE" 2>/dev/null || true; }
warn() { echo -e "  ${YELLOW}  !${NC} $1"; echo "[$TIMESTAMP] WARN: $1" >> "$LOG_FILE" 2>/dev/null || true; }
err()  { echo -e "  ${RED}  ✗${NC} $1"; echo "[$TIMESTAMP] ERR: $1"    >> "$LOG_FILE" 2>/dev/null || true; }
info() { echo -e "  ${CYAN}  i${NC} $1"; }

header() {
  echo ""
  draw_title "$1"
  echo ""
}

validate_index() {
  local input="$1" max="$2"
  [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= max ))
}

# Kullanıcıdan input al. Boş bırakılırsa:
#   - default varsa default'u kullanır (return 0)
#   - default yoksa iptal sayar (return 1)
# Kullanım: prompt_input varname "Label" [default]
prompt_input() {
  local varname="$1" prompt="$2" default="${3:-}"
  if [[ -n "$default" ]]; then
    echo -ne "  $prompt ${DIM}[$default]${NC}: "
  else
    echo -ne "  $prompt ${DIM}($(t empty_cancel))${NC}: "
  fi
  local _val
  read -r _val
  if [[ -z "$_val" && -z "$default" ]]; then
    return 1
  fi
  printf -v "$varname" '%s' "${_val:-$default}"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "$(t requires_root)"
    err "$(t run_as_root "$0")"
    exit 1
  fi
}

nginx_installed() { command -v nginx &>/dev/null; }

date_to_epoch() {
  local d="$1"
  if date -d "$d" +%s &>/dev/null 2>&1; then
    date -d "$d" +%s
  else
    date -j -f "%b %d %T %Y %Z" "$d" +%s 2>/dev/null || echo 0
  fi
}

# Servis komutları (OS'a göre)
svc() {
  local action="$1" svc_name="${2:-nginx}"
  case "$SERVICE_CMD" in
    systemctl)       systemctl "$action" "$svc_name" ;;
    "brew services") brew services "$action" "$svc_name" ;;
    rc-service)      rc-service "$svc_name" "$action" ;;
    *)               service "$svc_name" "$action" ;;
  esac
}

svc_is_active() {
  case "$SERVICE_CMD" in
    systemctl)       systemctl is-active --quiet nginx 2>/dev/null ;;
    "brew services") brew services list 2>/dev/null | grep -q "nginx.*started" ;;
    rc-service)      rc-service nginx status 2>/dev/null | grep -q started ;;
    *)               service nginx status &>/dev/null ;;
  esac
}

apply_os_settings() {
  case "$OS_ID" in
    ubuntu|debian|raspbian|linuxmint|pop)
      OS_FAMILY="debian"
      PKG_INSTALL="apt-get install -y"; PKG_UPDATE="apt-get update"
      SERVICE_CMD="systemctl"
      NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
      NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
      NGINX_LOG_DIR="/var/log/nginx"; NGINX_CONF="/etc/nginx/nginx.conf"
      CERTBOT_PKG="certbot python3-certbot-nginx"
      ;;
    rhel|centos|almalinux|rocky|fedora|ol)
      OS_FAMILY="rhel"
      PKG_INSTALL="dnf install -y"; PKG_UPDATE="dnf check-update || true"
      command -v dnf &>/dev/null || { PKG_INSTALL="yum install -y"; PKG_UPDATE="yum check-update || true"; }
      SERVICE_CMD="systemctl"
      NGINX_SITES_AVAILABLE="/etc/nginx/conf.d"
      NGINX_SITES_ENABLED="/etc/nginx/conf.d"
      NGINX_LOG_DIR="/var/log/nginx"; NGINX_CONF="/etc/nginx/nginx.conf"
      CERTBOT_PKG="certbot python3-certbot-nginx"
      ;;
    arch|manjaro|endeavouros)
      OS_FAMILY="arch"
      PKG_INSTALL="pacman -S --noconfirm"; PKG_UPDATE="pacman -Sy"
      SERVICE_CMD="systemctl"
      NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
      NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
      NGINX_LOG_DIR="/var/log/nginx"; NGINX_CONF="/etc/nginx/nginx.conf"
      CERTBOT_PKG="certbot certbot-nginx"
      ;;
    alpine)
      OS_FAMILY="alpine"
      PKG_INSTALL="apk add --no-cache"; PKG_UPDATE="apk update"
      SERVICE_CMD="rc-service"
      NGINX_SITES_AVAILABLE="/etc/nginx/conf.d"
      NGINX_SITES_ENABLED="/etc/nginx/conf.d"
      NGINX_LOG_DIR="/var/log/nginx"; NGINX_CONF="/etc/nginx/nginx.conf"
      CERTBOT_PKG="certbot certbot-nginx"
      ;;
    macos)
      OS_FAMILY="macos"
      PKG_INSTALL="brew install"; PKG_UPDATE="brew update"
      SERVICE_CMD="brew services"
      NGINX_SITES_AVAILABLE="/usr/local/etc/nginx/servers"
      NGINX_SITES_ENABLED="/usr/local/etc/nginx/servers"
      NGINX_LOG_DIR="/usr/local/var/log/nginx"
      NGINX_CONF="/usr/local/etc/nginx/nginx.conf"
      CERTBOT_PKG="certbot"
      ;;
  esac
}

# İŞLETİM SİSTEMİ ALGILAMA & SEÇİM
detect_os() {
  if [[ "$(uname)" == "Darwin" ]]; then
    OS_ID="macos"; apply_os_settings; return 0
  fi

  if [[ -f /etc/os-release ]]; then
    local id
    id=$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || true)
    OS_ID="$id"
    apply_os_settings
    [[ -n "$OS_FAMILY" ]] && return 0
  fi

  return 1
}

os_label() {
  case "$OS_FAMILY" in
    debian) echo "$(t os_label_debian)" ;;
    rhel)   echo "$(t os_label_rhel)"   ;;
    arch)   echo "$(t os_label_arch)"   ;;
    alpine) echo "$(t os_label_alpine)" ;;
    macos)  echo "$(t os_label_macos)"  ;;
    *)      echo "$(t os_label_unknown)" ;;
  esac
}

draw_banner() {
  echo -e "${BOLD}${BLUE}"
  echo "    ███╗   ██╗ ██████╗ ██╗███╗   ██╗██╗  ██╗"
  echo "    ████╗  ██║██╔════╝ ██║████╗  ██║╚██╗██╔╝"
  echo "    ██╔██╗ ██║██║  ███╗██║██╔██╗ ██║ ╚███╔╝ "
  echo "    ██║╚██╗██║██║   ██║██║██║╚██╗██║ ██╔██╗ "
  echo "    ██║ ╚████║╚██████╔╝██║██║ ╚████║██╔╝ ██╗"
  echo "    ╚═╝  ╚═══╝ ╚═════╝ ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝"
  echo -e "${NC}"
  echo -e "      ${DIM}$(t banner_subtitle)${NC}"
  echo ""
}

os_select_menu() {
  header "$(t os_select_title)"
  draw_top
  draw_row "  ${WHITE}1${NC}  Ubuntu / Debian / Mint / Pop!_OS"
  draw_row "  ${WHITE}2${NC}  RHEL / CentOS / Alma / Rocky / Fedora"
  draw_row "  ${WHITE}3${NC}  Arch Linux / Manjaro / EndeavourOS"
  draw_row "  ${WHITE}4${NC}  Alpine Linux"
  draw_row "  ${WHITE}5${NC}  macOS (Homebrew)"
  draw_bottom
  draw_prompt
  read -r sel

  case "$sel" in
    1) OS_ID="ubuntu" ;;
    2) OS_ID="rhel"   ;;
    3) OS_ID="arch"   ;;
    4) OS_ID="alpine" ;;
    5) OS_ID="macos"  ;;
    *) warn "$(t invalid_choice)"; os_select_menu; return ;;
  esac

  apply_os_settings
  log "$(t os_manual "$OS_ID")"
}

os_init() {
  clear
  echo ""
  draw_banner

  info "$(t os_detecting)"
  echo ""

  if detect_os; then
    draw_top
    draw_row "  ${DIM}OS${NC}       ${GREEN}${OS_ID^}${NC} — $(os_label)"
    draw_row "  ${DIM}$(t os_pkg)${NC}    ${CYAN}${PKG_INSTALL%% *}${NC}"
    draw_row "  ${DIM}$(t os_service)${NC}   ${CYAN}${SERVICE_CMD}${NC}"
    draw_row "  ${DIM}$(t os_config)${NC}   ${CYAN}${NGINX_SITES_AVAILABLE}${NC}"
    draw_bottom
    echo ""
    echo -ne "  $(t os_continue) ${DIM}[${MSG[confirm_yes_default]}]${NC} "
    read -r confirm
    if [[ "${confirm,,}" == "${MSG[confirm_no_char]}" ]]; then
      os_select_menu
    fi
  else
    warn "$(t os_not_detected)"
    os_select_menu
  fi
}

# RHEL/Alpine için sites-available notu
rhel_sites_note() {
  if [[ "$OS_FAMILY" == "rhel" || "$OS_FAMILY" == "alpine" ]]; then
    info "$(t rhel_note1)"
    info "$(t rhel_note2 "$NGINX_SITES_AVAILABLE")"
    echo ""
  fi
}

# CONFIG YÖNETİMİ
config_menu() {
  clear
  echo ""
  draw_banner
  header "$(t config_title)"
  rhel_sites_note
  draw_top
  draw_row "  ${WHITE}1${NC}  $(t config_list)"
  draw_row "  ${WHITE}2${NC}  $(t config_enable)"
  draw_row "  ${WHITE}3${NC}  $(t config_disable)"
  draw_row "  ${WHITE}4${NC}  $(t config_create)"
  draw_row "  ${WHITE}5${NC}  $(t config_profile)"
  draw_separator
  draw_row "  ${WHITE}6${NC}  $(t config_edit) ${DIM}(EDITOR)${NC}"
  draw_row "  ${WHITE}7${NC}  $(t config_diff) ${DIM}(diff)${NC}"
  draw_separator
  draw_row "  ${WHITE}8${NC}  $(t config_test) ${DIM}(nginx -t)${NC}"
  draw_row "  ${WHITE}9${NC}  $(t config_reload)"
  draw_bottom
  draw_footer
  draw_prompt
  read -r choice
  case "$choice" in
    1) config_list ;;  2) config_enable ;;  3) config_disable ;;
    4) config_create ;; 5) config_profile ;; 6) config_edit ;;
    7) config_diff ;; 8) config_test ;; 9) config_reload ;;
    0) main_menu ;;    q|Q) echo -e "\n  ${GREEN}$(t goodbye)${NC}\n"; exit 0 ;;
    *) warn "$(t invalid_choice)"; config_menu ;;
  esac
}

config_list() {
  header "$(t config_list_title)"
  echo ""
  if [[ "$OS_FAMILY" == "debian" || "$OS_FAMILY" == "arch" ]]; then
    ls "$NGINX_SITES_AVAILABLE" 2>/dev/null | while read -r site; do
      if [[ -L "$NGINX_SITES_ENABLED/$site" ]]; then
        echo -e "    ${GREEN}●${NC}  $site ${DIM}($(t active))${NC}"
      else
        echo -e "    ${RED}○${NC}  $site ${DIM}($(t inactive))${NC}"
      fi
    done || info "$(t no_site_found)"
  else
    ls "$NGINX_SITES_AVAILABLE"/*.conf 2>/dev/null | while read -r f; do
      echo -e "    ${GREEN}●${NC}  $(basename "$f") ${DIM}($(t active))${NC}"
    done || info "$(t no_site_found)"
  fi
  pause_prompt; config_menu
}

config_enable() {
  header "$(t config_enable_title)"; require_root
  if [[ "$OS_FAMILY" != "debian" && "$OS_FAMILY" != "arch" ]]; then
    warn "$(t rhel_conf_note)"
    pause_prompt; config_menu; return
  fi
  mkdir -p "$NGINX_SITES_AVAILABLE" "$NGINX_SITES_ENABLED"
  mapfile -t sites < <(ls "$NGINX_SITES_AVAILABLE" 2>/dev/null)
  [[ ${#sites[@]} -eq 0 ]] && { warn "$(t sites_avail_empty)"; config_menu; return; }
  echo ""
  for i in "${!sites[@]}"; do
    echo -e "    ${WHITE}$((i+1))${NC}  ${sites[$i]}"
  done
  echo ""
  prompt_input num "$(t prompt_site_num)" || { config_menu; return; }
  validate_index "$num" "${#sites[@]}" || { warn "$(t invalid_choice)"; pause_prompt; config_menu; return; }
  site="${sites[$((num-1))]}"
  if [[ -L "$NGINX_SITES_ENABLED/$site" ]]; then
    warn "$(t site_already_active "$site")"
  else
    ln -s "$NGINX_SITES_AVAILABLE/$site" "$NGINX_SITES_ENABLED/$site"
    nginx -t && svc reload nginx && log "$(t site_enabled "$site")" || err "$(t config_error)"
  fi
  pause_prompt; config_menu
}

config_disable() {
  header "$(t config_disable_title)"; require_root
  if [[ "$OS_FAMILY" != "debian" && "$OS_FAMILY" != "arch" ]]; then
    warn "$(t rhel_disable_note)"
    pause_prompt; config_menu; return
  fi
  mapfile -t sites < <(ls "$NGINX_SITES_ENABLED" 2>/dev/null)
  [[ ${#sites[@]} -eq 0 ]] && { warn "$(t no_active_site)"; config_menu; return; }
  echo ""
  for i in "${!sites[@]}"; do
    echo -e "    ${WHITE}$((i+1))${NC}  ${sites[$i]}"
  done
  echo ""
  prompt_input num "$(t prompt_site_num)" || { config_menu; return; }
  validate_index "$num" "${#sites[@]}" || { warn "$(t invalid_choice)"; pause_prompt; config_menu; return; }
  site="${sites[$((num-1))]}"
  rm -f "$NGINX_SITES_ENABLED/$site"
  nginx -t && svc reload nginx && log "$(t site_disabled "$site")" || err "$(t reload_failed)"
  pause_prompt; config_menu
}

config_create() {
  header "$(t config_create_title)"; require_root
  prompt_input domain "$(t prompt_domain)" || { config_menu; return; }
  prompt_input root_dir "$(t prompt_root_dir)" "/var/www/$domain/html"
  prompt_input port "$(t prompt_port)" "80"
  mkdir -p "$root_dir"

  if [[ "$OS_FAMILY" == "rhel" || "$OS_FAMILY" == "alpine" ]]; then
    mkdir -p "$NGINX_SITES_AVAILABLE"
    conf_path="$NGINX_SITES_AVAILABLE/${domain}.conf"
  else
    mkdir -p "$NGINX_SITES_AVAILABLE"
    conf_path="$NGINX_SITES_AVAILABLE/$domain"
  fi

  cat > "$conf_path" <<EOF
server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    root $root_dir;
    index index.html index.htm index.php;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    location / { try_files \$uri \$uri/ =404; }
}
EOF

  log "$(t config_created "$conf_path")"

  if [[ "$OS_FAMILY" == "debian" || "$OS_FAMILY" == "arch" ]]; then
    echo -ne "  $(t activate_now) ${DIM}[${MSG[confirm_yes_default]}]${NC}: "
    read -r activate
    if [[ "${activate,,}" != "${MSG[confirm_no_char]}" ]]; then
      mkdir -p "$NGINX_SITES_ENABLED"
      ln -sf "$conf_path" "$NGINX_SITES_ENABLED/$domain"
      nginx -t && svc reload nginx && log "$(t activated "$domain")"
    fi
  else
    nginx -t && svc reload nginx && log "$(t activated "$domain")"
  fi

  pause_prompt; config_menu
}

# ── Profil / Şablon Sistemi ──────────────────────────────────

# Ortak: config dosyasını yaz, etkinleştir, reload
profile_save_and_activate() {
  local domain="$1" conf_content="$2"

  if [[ "$OS_FAMILY" == "rhel" || "$OS_FAMILY" == "alpine" ]]; then
    mkdir -p "$NGINX_SITES_AVAILABLE"
    conf_path="$NGINX_SITES_AVAILABLE/${domain}.conf"
  else
    mkdir -p "$NGINX_SITES_AVAILABLE"
    conf_path="$NGINX_SITES_AVAILABLE/$domain"
  fi

  echo "$conf_content" > "$conf_path"
  log "$(t profile_created "$conf_path")"

  if [[ "$OS_FAMILY" == "debian" || "$OS_FAMILY" == "arch" ]]; then
    echo -ne "  $(t activate_now) ${DIM}[${MSG[confirm_yes_default]}]${NC}: "
    read -r activate
    if [[ "${activate,,}" != "${MSG[confirm_no_char]}" ]]; then
      mkdir -p "$NGINX_SITES_ENABLED"
      ln -sf "$conf_path" "$NGINX_SITES_ENABLED/$domain"
      nginx -t && svc reload nginx && log "$(t activated "$domain")"
    fi
  else
    nginx -t && svc reload nginx && log "$(t activated "$domain")"
  fi
}

# Ortak: PHP-FPM upstream bloğu
php_fpm_block() {
  cat <<'PHPBLK'
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_intercept_errors on;
    }
PHPBLK
}

# Ortak: proxy header bloğu
proxy_headers_block() {
  local upstream="$1"
  cat <<PRXBLK
        proxy_pass http://$upstream;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
PRXBLK
}

# Ortak: statik asset cache bloğu
static_cache_block() {
  cat <<'STBLK'
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|woff2?|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
STBLK
}

# ── Profil Ana Menü ──────────────────────────────────────────
config_profile() {
  header "$(t config_profile_title)"; require_root
  echo ""
  draw_top
  draw_row_center "${BOLD}${WHITE}$(t profile_select_cat)${NC}"
  draw_separator
  draw_row "  ${WHITE}1${NC}  $(t profile_cat_static) ${DIM}(React, Angular, Vue...)${NC}"
  draw_row "  ${WHITE}2${NC}  $(t profile_cat_php) ${DIM}(WP, Laravel, Symfony...)${NC}"
  draw_row "  ${WHITE}3${NC}  $(t profile_cat_node) ${DIM}(Next, Nuxt, Express...)${NC}"
  draw_row "  ${WHITE}4${NC}  $(t profile_cat_python) ${DIM}(Django, Flask, FastAPI...)${NC}"
  draw_row "  ${WHITE}5${NC}  $(t profile_cat_other) ${DIM}(Go, Rust, Ruby on Rails...)${NC}"
  draw_bottom
  draw_prompt
  read -r cat_choice

  case "$cat_choice" in
    1) profile_static_menu ;;
    2) profile_php_menu ;;
    3) profile_node_menu ;;
    4) profile_python_menu ;;
    5) profile_other_menu ;;
    *) warn "$(t invalid_choice)"; config_menu; return ;;
  esac
}

# ── Kategori 1: Statik / SPA ────────────────────────────────
profile_static_menu() {
  echo ""
  draw_top
  draw_row "  ${WHITE}1${NC}  $(t profile_static) ${DIM}(klasik HTML/CSS/JS)${NC}"
  draw_row "  ${WHITE}2${NC}  React ${DIM}(Create React App / Vite)${NC}"
  draw_row "  ${WHITE}3${NC}  Angular"
  draw_row "  ${WHITE}4${NC}  Vue.js ${DIM}(Vite)${NC}"
  draw_row "  ${WHITE}5${NC}  Svelte / SvelteKit ${DIM}(static adapter)${NC}"
  draw_bottom
  draw_prompt
  read -r tpl

  prompt_input domain "$(t prompt_domain)" || { config_menu; return; }
  prompt_input port "$(t prompt_port)" "80"
  local root_dir="/var/www/$domain/html"
  local conf_content=""

  case "$tpl" in
    1) # Klasik statik
      mkdir -p "$root_dir"
      conf_content=$(cat <<TMPL
server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    root $root_dir;
    index index.html index.htm;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }

$(static_cache_block)
}
TMPL
      )
      ;;
    2) # React
      root_dir="/var/www/$domain/build"
      prompt_input custom_root "$(t profile_build_dir)" "$root_dir"
      root_dir="$custom_root"
      mkdir -p "$root_dir"
      conf_content=$(cat <<TMPL
server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    root $root_dir;
    index index.html;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;

    # React Router — tüm route'lar index.html'e yönlendirilir
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # static/ klasörü agresif cache
    location /static/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

$(static_cache_block)

    # API proxy (opsiyonel, backend varsa yorum kaldırın)
    # location /api/ {
    #     proxy_pass http://127.0.0.1:5000;
    #     proxy_set_header Host \$host;
    #     proxy_set_header X-Real-IP \$remote_addr;
    # }
}
TMPL
      )
      ;;
    3) # Angular
      root_dir="/var/www/$domain/dist"
      prompt_input custom_root "$(t profile_dist_dir)" "$root_dir"
      root_dir="$custom_root"
      mkdir -p "$root_dir"
      conf_content=$(cat <<TMPL
server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    root $root_dir;
    index index.html;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;

    # Angular Router — deep link desteği
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Angular hashed assets — uzun cache
    location ~* \.[a-f0-9]{16,}\.(js|css)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

$(static_cache_block)
}
TMPL
      )
      ;;
    4) # Vue.js
      root_dir="/var/www/$domain/dist"
      prompt_input custom_root "$(t profile_dist_dir)" "$root_dir"
      root_dir="$custom_root"
      mkdir -p "$root_dir"
      conf_content=$(cat <<TMPL
server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    root $root_dir;
    index index.html;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;

    # Vue Router (history mode)
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Vite hashed assets
    location /assets/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

$(static_cache_block)
}
TMPL
      )
      ;;
    5) # Svelte / SvelteKit static
      root_dir="/var/www/$domain/build"
      prompt_input custom_root "$(t profile_build_dir)" "$root_dir"
      root_dir="$custom_root"
      mkdir -p "$root_dir"
      conf_content=$(cat <<TMPL
server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    root $root_dir;
    index index.html;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;

    # SvelteKit SPA fallback
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # _app/ immutable assets (SvelteKit)
    location /_app/immutable/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

$(static_cache_block)
}
TMPL
      )
      ;;
    *) warn "$(t invalid_choice)"; config_menu; return ;;
  esac

  profile_save_and_activate "$domain" "$conf_content"
  pause_prompt; config_menu
}

# ── Kategori 2: PHP Projeleri ────────────────────────────────
profile_php_menu() {
  echo ""
  draw_top
  draw_row "  ${WHITE}1${NC}  WordPress"
  draw_row "  ${WHITE}2${NC}  Laravel"
  draw_row "  ${WHITE}3${NC}  Symfony"
  draw_row "  ${WHITE}4${NC}  Drupal"
  draw_row "  ${WHITE}5${NC}  $(t profile_general_php) ${DIM}(PHP-FPM)${NC}"
  draw_bottom
  draw_prompt
  read -r tpl

  prompt_input domain "$(t prompt_domain)" || { config_menu; return; }
  prompt_input port "$(t prompt_port)" "80"
  local root_dir="/var/www/$domain/html"
  local conf_content=""

  case "$tpl" in
    1) # WordPress
      mkdir -p "$root_dir"
      conf_content=$(cat <<TMPL
server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    root $root_dir;
    index index.php index.html;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

$(php_fpm_block)

    # WP uploads cache
    location ~* /wp-content/uploads/.*\.(jpg|jpeg|png|gif|webp|svg|css|js)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

$(static_cache_block)

    # Güvenlik
    location ~ /\.ht { deny all; }
    location = /xmlrpc.php { deny all; }
    location ~* /wp-config\.php { deny all; }
    location ~* /readme\.html { deny all; }
}
TMPL
      )
      ;;
    2) # Laravel
      root_dir="/var/www/$domain/public"
      mkdir -p "$root_dir"
      conf_content=$(cat <<TMPL
server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    root $root_dir;
    index index.php;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    client_max_body_size 32M;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

$(php_fpm_block)

    # Laravel Mix / Vite hashed assets
    location /build/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

$(static_cache_block)

    location ~ /\.(?!well-known).* { deny all; }
}
TMPL
      )
      ;;
    3) # Symfony
      root_dir="/var/www/$domain/public"
      mkdir -p "$root_dir"
      conf_content=$(cat <<TMPL
server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    root $root_dir;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    client_max_body_size 32M;

    location / {
        try_files \$uri /index.php\$is_args\$args;
    }

    location ~ ^/index\.php(/|$) {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$document_root;
        internal;
    }

    # diğer .php dosyalarına erişimi engelle
    location ~ \.php$ { return 404; }

    location /bundles/ {
        expires 30d;
        add_header Cache-Control "public";
    }

$(static_cache_block)

    location ~ /\. { deny all; }
}
TMPL
      )
      ;;
    4) # Drupal
      mkdir -p "$root_dir"
      conf_content=$(cat <<TMPL
server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    root $root_dir;
    index index.php;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    client_max_body_size 64M;

    location / {
        try_files \$uri /index.php?\$query_string;
    }

$(php_fpm_block)

    # Drupal files dizini
    location ~ ^/sites/.*/files/styles/ {
        try_files \$uri @rewrite;
    }

    location @rewrite {
        rewrite ^ /index.php;
    }

    # Güvenlik
    location ~ /\.ht { deny all; }
    location ~ (^|/)\. { return 403; }
    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt { allow all; log_not_found off; access_log off; }
    location ~* \.(txt|log)$ { deny all; }

$(static_cache_block)
}
TMPL
      )
      ;;
    5) # Genel PHP
      mkdir -p "$root_dir"
      conf_content=$(cat <<TMPL
server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    root $root_dir;
    index index.php index.html;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    client_max_body_size 32M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

$(php_fpm_block)

$(static_cache_block)

    location ~ /\. { deny all; }
}
TMPL
      )
      ;;
    *) warn "$(t invalid_choice)"; config_menu; return ;;
  esac

  profile_save_and_activate "$domain" "$conf_content"
  pause_prompt; config_menu
}

# ── Kategori 3: Node.js Projeleri ────────────────────────────
profile_node_menu() {
  echo ""
  draw_top
  draw_row "  ${WHITE}1${NC}  Next.js ${DIM}(SSR)${NC}"
  draw_row "  ${WHITE}2${NC}  Nuxt ${DIM}(SSR)${NC}"
  draw_row "  ${WHITE}3${NC}  Remix"
  draw_row "  ${WHITE}4${NC}  Express / Fastify / Koa"
  draw_row "  ${WHITE}5${NC}  SvelteKit ${DIM}(node adapter)${NC}"
  draw_row "  ${WHITE}6${NC}  Astro ${DIM}(SSR)${NC}"
  draw_bottom
  draw_prompt
  read -r tpl

  prompt_input domain "$(t prompt_domain)" || { config_menu; return; }
  prompt_input port "$(t prompt_port)" "80"
  prompt_input backend_port "$(t prompt_backend_port)" "3000"
  local upstream="${domain//./_}_backend"
  local conf_content=""

  case "$tpl" in
    1) # Next.js
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
    keepalive 64;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    client_max_body_size 16M;

    # Next.js immutable build assets
    location /_next/static/ {
        proxy_pass http://$upstream;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # Next.js image optimization
    location /_next/image {
        proxy_pass http://$upstream;
        proxy_set_header Host \$host;
        expires 30d;
        add_header Cache-Control "public";
    }

    # Public klasörü statik dosyalar
    location /static/ {
        proxy_pass http://$upstream;
        expires 30d;
        add_header Cache-Control "public";
    }

    location / {
$(proxy_headers_block "$upstream")
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass \$http_upgrade;
    }
}
TMPL
      )
      ;;
    2) # Nuxt
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
    keepalive 64;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;

    # Nuxt build assets (_nuxt/)
    location /_nuxt/ {
        proxy_pass http://$upstream;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # Nitro/Nuxt payload
    location /_payload.json {
        proxy_pass http://$upstream;
        expires 0;
        add_header Cache-Control "no-cache";
    }

    location / {
$(proxy_headers_block "$upstream")
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass \$http_upgrade;
    }
}
TMPL
      )
      ;;
    3) # Remix
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
    keepalive 64;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;

    # Remix build assets
    location /build/ {
        proxy_pass http://$upstream;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    location /favicon.ico {
        proxy_pass http://$upstream;
        expires 30d;
    }

    location / {
$(proxy_headers_block "$upstream")
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass \$http_upgrade;
    }
}
TMPL
      )
      ;;
    4) # Express / Fastify / Koa
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
    keepalive 64;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    client_max_body_size 16M;

    # Statik dosyalar (varsa public/ dizininden serve)
    location /public/ {
        alias /var/www/$domain/public/;
        expires 30d;
        add_header Cache-Control "public";
    }

    location / {
$(proxy_headers_block "$upstream")
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass \$http_upgrade;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
TMPL
      )
      ;;
    5) # SvelteKit (node adapter)
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
    keepalive 64;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;

    # SvelteKit immutable assets
    location /_app/immutable/ {
        proxy_pass http://$upstream;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    location / {
$(proxy_headers_block "$upstream")
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass \$http_upgrade;
    }
}
TMPL
      )
      ;;
    6) # Astro SSR
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
    keepalive 64;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;

    # Astro hashed assets
    location /_astro/ {
        proxy_pass http://$upstream;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    location / {
$(proxy_headers_block "$upstream")
        proxy_cache_bypass \$http_upgrade;
    }
}
TMPL
      )
      ;;
    *) warn "$(t invalid_choice)"; config_menu; return ;;
  esac

  profile_save_and_activate "$domain" "$conf_content"
  pause_prompt; config_menu
}

# ── Kategori 4: Python Projeleri ─────────────────────────────
profile_python_menu() {
  echo ""
  draw_top
  draw_row "  ${WHITE}1${NC}  Django ${DIM}(Gunicorn)${NC}"
  draw_row "  ${WHITE}2${NC}  Flask ${DIM}(Gunicorn)${NC}"
  draw_row "  ${WHITE}3${NC}  FastAPI ${DIM}(Uvicorn)${NC}"
  draw_row "  ${WHITE}4${NC}  Genel Python WSGI"
  draw_bottom
  draw_prompt
  read -r tpl

  prompt_input domain "$(t prompt_domain)" || { config_menu; return; }
  prompt_input port "$(t prompt_port)" "80"
  prompt_input backend_port "$(t prompt_backend_port)" "8000"
  local upstream="${domain//./_}_app"
  local conf_content=""

  case "$tpl" in
    1) # Django
      prompt_input project_dir "$(t profile_project_dir)" "/var/www/$domain"
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    client_max_body_size 32M;

    # Django static dosyalar (collectstatic çıktısı)
    location /static/ {
        alias $project_dir/staticfiles/;
        expires 30d;
        add_header Cache-Control "public";
    }

    # Django media dosyaları (kullanıcı yüklemeleri)
    location /media/ {
        alias $project_dir/media/;
        expires 7d;
        add_header Cache-Control "public";
    }

    # Django admin statik dosyaları (static/ altında zaten var)

    location / {
$(proxy_headers_block "$upstream")
    }

    # Güvenlik
    location ~ /\. { deny all; }
}
TMPL
      )
      ;;
    2) # Flask
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    client_max_body_size 16M;

    # Flask static klasörü
    location /static/ {
        alias /var/www/$domain/static/;
        expires 30d;
        add_header Cache-Control "public";
    }

    location / {
$(proxy_headers_block "$upstream")
    }
}
TMPL
      )
      ;;
    3) # FastAPI
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
    keepalive 32;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    client_max_body_size 16M;

    # FastAPI docs (Swagger UI & ReDoc)
    location /docs {
$(proxy_headers_block "$upstream")
    }

    location /redoc {
$(proxy_headers_block "$upstream")
    }

    location /openapi.json {
$(proxy_headers_block "$upstream")
        expires 1h;
    }

    # WebSocket desteği (varsa)
    location /ws {
$(proxy_headers_block "$upstream")
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
    }

    location / {
$(proxy_headers_block "$upstream")
    }
}
TMPL
      )
      ;;
    4) # Genel Python WSGI
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    client_max_body_size 16M;

    location /static/ {
        alias /var/www/$domain/static/;
        expires 30d;
    }

    location / {
$(proxy_headers_block "$upstream")
    }
}
TMPL
      )
      ;;
    *) warn "$(t invalid_choice)"; config_menu; return ;;
  esac

  profile_save_and_activate "$domain" "$conf_content"
  pause_prompt; config_menu
}

# ── Kategori 5: Diğer ───────────────────────────────────────
profile_other_menu() {
  echo ""
  draw_top
  draw_row "  ${WHITE}1${NC}  Go ${DIM}(net/http, Gin, Fiber...)${NC}"
  draw_row "  ${WHITE}2${NC}  Rust ${DIM}(Actix, Axum, Rocket...)${NC}"
  draw_row "  ${WHITE}3${NC}  Ruby on Rails ${DIM}(Puma)${NC}"
  draw_row "  ${WHITE}4${NC}  Java / Spring Boot"
  draw_row "  ${WHITE}5${NC}  .NET / ASP.NET Core ${DIM}(Kestrel)${NC}"
  draw_bottom
  draw_prompt
  read -r tpl

  prompt_input domain "$(t prompt_domain)" || { config_menu; return; }
  prompt_input port "$(t prompt_port)" "80"
  prompt_input backend_port "$(t prompt_backend_port)" "8080"
  local upstream="${domain//./_}_backend"
  local conf_content=""

  case "$tpl" in
    1) # Go
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
    keepalive 128;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;

    location / {
$(proxy_headers_block "$upstream")
        proxy_buffering off;
    }

    # Statik dosyalar (varsa)
    location /static/ {
        alias /var/www/$domain/static/;
        expires 30d;
    }
}
TMPL
      )
      ;;
    2) # Rust
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
    keepalive 128;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;

    location / {
$(proxy_headers_block "$upstream")
        proxy_buffering off;
    }

    location /static/ {
        alias /var/www/$domain/static/;
        expires 30d;
    }
}
TMPL
      )
      ;;
    3) # Ruby on Rails (Puma)
      backend_port="${backend_port:-3000}"
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    root /var/www/$domain/public;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    client_max_body_size 32M;

    # Rails asset pipeline
    location /assets/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        gzip_static on;
    }

    # Rails packs (Webpacker/Shakapacker)
    location /packs/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        gzip_static on;
    }

    # Önce statik dosyalara bak, yoksa Puma'ya yönlendir
    location / {
        try_files \$uri @rails;
    }

    location @rails {
$(proxy_headers_block "$upstream")
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
TMPL
      )
      ;;
    4) # Java / Spring Boot
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
    keepalive 32;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    client_max_body_size 32M;

    # Spring Boot actuator (isteğe bağlı engelleme)
    # location /actuator/ { deny all; }

    location / {
$(proxy_headers_block "$upstream")
        proxy_connect_timeout 90s;
        proxy_send_timeout 90s;
        proxy_read_timeout 90s;
    }

    location /static/ {
        alias /var/www/$domain/static/;
        expires 30d;
    }
}
TMPL
      )
      ;;
    5) # .NET / ASP.NET Core
      backend_port="${backend_port:-5000}"
      conf_content=$(cat <<TMPL
upstream $upstream {
    server 127.0.0.1:$backend_port;
    keepalive 32;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;
    client_max_body_size 32M;

    # Kestrel proxy
    location / {
$(proxy_headers_block "$upstream")
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass \$http_upgrade;
    }

    # wwwroot statik dosyaları
    location /lib/ {
        proxy_pass http://$upstream;
        expires 30d;
        add_header Cache-Control "public";
    }

    location /css/ {
        proxy_pass http://$upstream;
        expires 30d;
    }

    location /js/ {
        proxy_pass http://$upstream;
        expires 30d;
    }
}
TMPL
      )
      ;;
    *) warn "$(t invalid_choice)"; config_menu; return ;;
  esac

  profile_save_and_activate "$domain" "$conf_content"
  pause_prompt; config_menu
}

# Config Düzenleme
config_edit() {
  header "$(t config_edit_title)"
  local editor="${EDITOR:-vi}"

  mapfile -t configs < <(find "$NGINX_SITES_AVAILABLE" -maxdepth 1 -type f 2>/dev/null | sort)
  [[ -f "$NGINX_CONF" ]] && configs=("$NGINX_CONF" "${configs[@]}")

  if [[ ${#configs[@]} -eq 0 ]]; then
    warn "$(t no_config_found)"
    pause_prompt; config_menu; return
  fi
  echo ""
  for i in "${!configs[@]}"; do
    echo -e "    ${WHITE}$((i+1))${NC}  ${configs[$i]}"
  done
  echo ""
  prompt_input num "$(t prompt_file_num)" || { config_menu; return; }
  validate_index "$num" "${#configs[@]}" || { warn "$(t invalid_choice)"; pause_prompt; config_menu; return; }
  local target="${configs[$((num-1))]}"
  [[ ! -f "$target" ]] && { err "$(t no_config_found)"; pause_prompt; config_menu; return; }

  info "$(t opening "$editor $target")"
  $editor "$target"
  log "$(t edited "$target")"
  pause_prompt; config_menu
}

# Config Karşılaştırma
config_diff() {
  header "$(t config_diff_title)"

  mapfile -t configs < <(find "$NGINX_SITES_AVAILABLE" -maxdepth 1 -type f 2>/dev/null | sort)
  [[ -f "$NGINX_CONF" ]] && configs=("$NGINX_CONF" "${configs[@]}")

  if [[ ${#configs[@]} -lt 2 ]]; then
    warn "$(t need_2_configs)"
    pause_prompt; config_menu; return
  fi
  echo ""
  for i in "${!configs[@]}"; do
    echo -e "    ${WHITE}$((i+1))${NC}  ${configs[$i]}"
  done
  echo ""
  prompt_input num1 "$(t prompt_file_num1)" || { config_menu; return; }
  prompt_input num2 "$(t prompt_file_num2)" || { config_menu; return; }
  validate_index "$num1" "${#configs[@]}" || { warn "$(t invalid_choice)"; pause_prompt; config_menu; return; }
  validate_index "$num2" "${#configs[@]}" || { warn "$(t invalid_choice)"; pause_prompt; config_menu; return; }

  local file1="${configs[$((num1-1))]}" file2="${configs[$((num2-1))]}"
  echo ""
  if command -v colordiff &>/dev/null; then
    colordiff "$file1" "$file2" || true
  else
    diff --color=auto "$file1" "$file2" 2>/dev/null || diff "$file1" "$file2" || true
  fi
  pause_prompt; config_menu
}

config_test() {
  header "$(t config_test_title)"
  nginx -t && log "$(t config_valid)" || err "$(t config_error)"
  pause_prompt; config_menu
}

config_reload() {
  header "$(t config_reload_title)"; require_root
  nginx -t && svc reload nginx && log "$(t config_reloaded)" || err "$(t reload_failed)"
  pause_prompt; config_menu
}

# SSL SERTİFİKA (CERTBOT)
ssl_menu() {
  clear
  echo ""
  draw_banner
  header "$(t ssl_title)"
  draw_top
  draw_row "  ${WHITE}1${NC}  $(t ssl_list)"
  draw_row "  ${WHITE}2${NC}  $(t ssl_obtain) ${DIM}(Let's Encrypt)${NC}"
  draw_row "  ${WHITE}3${NC}  $(t ssl_renew) ${DIM}(renew)${NC}"
  draw_separator
  draw_row "  ${WHITE}4${NC}  $(t ssl_expiry)"
  draw_row "  ${WHITE}5${NC}  $(t ssl_cron)"
  draw_separator
  draw_row "  ${WHITE}6${NC}  $(t ssl_self_signed)"
  draw_row "  ${WHITE}7${NC}  $(t ssl_cloudflare)"
  draw_bottom
  draw_footer
  draw_prompt
  read -r choice
  case "$choice" in
    1) ssl_list ;; 2) ssl_obtain ;; 3) ssl_renew ;;
    4) ssl_check_expiry ;; 5) ssl_cron_setup ;;
    6) ssl_self_signed ;; 7) ssl_cloudflare_origin ;;
    0) main_menu ;;
    q|Q) echo -e "\n  ${GREEN}$(t goodbye)${NC}\n"; exit 0 ;;
    *) warn "$(t invalid_choice)"; ssl_menu ;;
  esac
}

certbot_install() {
  command -v certbot &>/dev/null && return 0
  err "$(t ssl_certbot_missing)"
  echo -ne "  $(t ssl_certbot_install) ${DIM}[${MSG[confirm_yes_default]}]${NC}: "
  read -r inst
  [[ "${inst,,}" == "${MSG[confirm_no_char]}" ]] && return 1
  require_root
  case "$OS_FAMILY" in
    debian) $PKG_UPDATE || true; $PKG_INSTALL $CERTBOT_PKG ;;
    rhel)   $PKG_INSTALL epel-release 2>/dev/null || true; $PKG_INSTALL $CERTBOT_PKG ;;
    arch|alpine) $PKG_UPDATE || true; $PKG_INSTALL $CERTBOT_PKG ;;
    macos)  $PKG_INSTALL $CERTBOT_PKG ;;
  esac
  command -v certbot &>/dev/null && log "$(t ssl_certbot_installed)" || { err "$(t ssl_install_failed)"; return 1; }
}

ssl_list() {
  header "$(t ssl_list_title)"
  certbot_install || { ssl_menu; return; }
  certbot certificates 2>/dev/null || warn "$(t ssl_no_cert)"
  pause_prompt; ssl_menu
}

ssl_obtain() {
  header "$(t ssl_obtain_title)"; require_root
  certbot_install || { ssl_menu; return; }
  prompt_input domain "$(t prompt_domain)" || { ssl_menu; return; }
  prompt_input email "$(t prompt_email)" || { ssl_menu; return; }
  prompt_input www "$(t prompt_www)" "E"
  domains="-d $domain"
  [[ "${www,,}" != "${MSG[confirm_no_char]}" ]] && domains="$domains -d www.$domain"
  certbot --nginx $domains --email "$email" --agree-tos --no-eff-email \
    && log "$(t ssl_obtained "$domain")" || err "$(t ssl_obtain_failed)"
  pause_prompt; ssl_menu
}

ssl_renew() {
  header "$(t ssl_renew_title)"; require_root
  certbot_install || { ssl_menu; return; }
  certbot renew --nginx && log "$(t ssl_renewed)" || warn "$(t ssl_renew_issue)"
  pause_prompt; ssl_menu
}

ssl_check_expiry() {
  header "$(t ssl_expiry_title)"
  CERT_DIR="/etc/letsencrypt/live"
  [[ "$OS_FAMILY" == "macos" ]] && CERT_DIR="/usr/local/etc/letsencrypt/live"
  if [[ ! -d "$CERT_DIR" ]]; then
    warn "$(t ssl_no_cert)"; ssl_menu; return
  fi
  echo ""
  draw_top
  draw_row "  ${BOLD}${WHITE}$(printf '%-22s %-16s %s' "$(t col_domain)" "$(t col_expiry)" "$(t col_remaining)")${NC}"
  draw_separator
  for cert_path in "$CERT_DIR"/*/cert.pem; do
    [[ -f "$cert_path" ]] || continue
    domain=$(basename "$(dirname "$cert_path")")
    expiry=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
    expiry_epoch=$(date_to_epoch "$expiry")
    days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))
    if (( days_left <= 7 )); then color=$RED
    elif (( days_left <= 30 )); then color=$YELLOW
    else color=$GREEN; fi
    draw_row "  $(printf '%-22s %-16s' "$domain" "$expiry")${color}$(t unit_days "$days_left")${NC}"
  done
  draw_bottom
  pause_prompt; ssl_menu
}

ssl_cron_setup() {
  header "$(t ssl_cron_title)"; require_root
  if [[ "$OS_FAMILY" == "macos" ]]; then
    warn "$(t ssl_cron_macos)"
    pause_prompt; ssl_menu; return
  fi
  if [[ "$OS_FAMILY" == "alpine" ]]; then
    echo "certbot renew --nginx --quiet" > /etc/periodic/weekly/certbot-renew
    chmod +x /etc/periodic/weekly/certbot-renew
    log "$(t ssl_cron_alpine)"
  else
    echo "0 3 * * * certbot renew --nginx --quiet >> /var/log/certbot-renew.log 2>&1" > /etc/cron.d/certbot-renew
    chmod 644 /etc/cron.d/certbot-renew
    log "$(t ssl_cron_set)"
  fi
  pause_prompt; ssl_menu
}

# Self-Signed Sertifika
ssl_self_signed() {
  header "$(t ssl_self_title)"; require_root
  prompt_input domain "$(t prompt_domain)" || { ssl_menu; return; }
  prompt_input days "$(t prompt_days)" "365"

  local ssl_dir="/etc/nginx/ssl/$domain"
  mkdir -p "$ssl_dir"

  openssl req -x509 -nodes -days "$days" -newkey rsa:2048 \
    -keyout "$ssl_dir/selfsigned.key" \
    -out "$ssl_dir/selfsigned.crt" \
    -subj "/CN=$domain/O=Self-Signed/C=TR" 2>/dev/null \
    && log "$(t ssl_self_created)" \
    || { err "$(t ssl_self_failed)"; pause_prompt; ssl_menu; return; }

  openssl dhparam -out "$ssl_dir/dhparam.pem" 2048 2>/dev/null &
  info "$(t ssl_dh_generating)"

  echo ""
  draw_top
  draw_row "  ${DIM}Sertifika${NC}  $ssl_dir/selfsigned.crt"
  draw_row "  ${DIM}Anahtar${NC}    $ssl_dir/selfsigned.key"
  draw_row "  ${DIM}DH Param${NC}   $ssl_dir/dhparam.pem"
  draw_bottom
  echo ""
  info "$(t ssl_config_lines)"
  echo ""
  echo -e "    ${DIM}ssl_certificate     $ssl_dir/selfsigned.crt;${NC}"
  echo -e "    ${DIM}ssl_certificate_key $ssl_dir/selfsigned.key;${NC}"

  pause_prompt; ssl_menu
}

# Cloudflare Origin CA
ssl_cloudflare_origin() {
  header "$(t ssl_cf_title)"; require_root
  info "$(t ssl_cf_info1)"
  info "$(t ssl_cf_info2)"
  echo ""

  prompt_input domain "$(t prompt_domain)" || { ssl_menu; return; }
  local ssl_dir="/etc/nginx/ssl/$domain"
  mkdir -p "$ssl_dir"

  prompt_input cert_file "$(t prompt_cert_file)" || { ssl_menu; return; }
  prompt_input key_file "$(t prompt_key_file)" || { ssl_menu; return; }

  if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
    err "$(t file_not_found)"; pause_prompt; ssl_menu; return
  fi

  cp "$cert_file" "$ssl_dir/cloudflare-origin.crt"
  cp "$key_file" "$ssl_dir/cloudflare-origin.key"
  chmod 600 "$ssl_dir/cloudflare-origin.key"

  log "$(t ssl_cf_installed)"
  echo ""
  draw_top
  draw_row "  ${DIM}Sertifika${NC}  $ssl_dir/cloudflare-origin.crt"
  draw_row "  ${DIM}Anahtar${NC}    $ssl_dir/cloudflare-origin.key"
  draw_bottom
  echo ""
  info "$(t ssl_config_lines)"
  echo ""
  echo -e "    ${DIM}ssl_certificate     $ssl_dir/cloudflare-origin.crt;${NC}"
  echo -e "    ${DIM}ssl_certificate_key $ssl_dir/cloudflare-origin.key;${NC}"
  echo -e "    ${DIM}ssl_client_certificate /etc/nginx/ssl/cloudflare-ca.pem;${NC}"
  echo -e "    ${DIM}ssl_verify_client on;${NC}"

  pause_prompt; ssl_menu
}

# LOG ANALİZİ
log_menu() {
  clear
  echo ""
  draw_banner
  header "$(t log_title)"
  draw_top
  draw_row "  ${WHITE}1${NC}  $(t log_tail) ${DIM}(tail -f)${NC}"
  draw_row "  ${WHITE}2${NC}  $(t log_errors)"
  draw_row "  ${WHITE}3${NC}  $(t log_top_ips)"
  draw_separator
  draw_row "  ${WHITE}4${NC}  $(t log_status_codes)"
  draw_row "  ${WHITE}5${NC}  $(t log_top_urls)"
  draw_row "  ${WHITE}6${NC}  $(t log_bandwidth)"
  draw_separator
  draw_row "  ${WHITE}7${NC}  $(t log_sizes)"
  draw_row "  ${WHITE}8${NC}  $(t log_date_filter)"
  draw_row "  ${WHITE}9${NC}  $(t log_export) ${DIM}(CSV/JSON)${NC}"
  draw_bottom
  draw_footer
  draw_prompt
  read -r choice
  case "$choice" in
    1) log_tail ;; 2) log_errors ;; 3) log_top_ips ;;
    4) log_status_codes ;; 5) log_top_urls ;; 6) log_bandwidth ;;
    7) log_sizes ;; 8) log_date_filter ;; 9) log_export ;;
    0) main_menu ;; q|Q) echo -e "\n  ${GREEN}$(t goodbye)${NC}\n"; exit 0 ;;
    *) warn "$(t invalid_choice)"; log_menu ;;
  esac
}

pick_log_file() {
  mapfile -t logs < <(find "$NGINX_LOG_DIR" -name "*.log" 2>/dev/null | sort)
  if [[ ${#logs[@]} -eq 0 ]]; then
    err "$(t log_dir_empty "$NGINX_LOG_DIR")"; return 1
  fi
  echo ""
  for i in "${!logs[@]}"; do
    echo -e "    ${WHITE}$((i+1))${NC}  ${logs[$i]}"
  done
  echo ""
  prompt_input num "$(t prompt_log_num)" "1"
  validate_index "$num" "${#logs[@]}" || { err "$(t invalid_number)"; return 1; }
  SELECTED_LOG="${logs[$((num-1))]}"
  [[ ! -f "$SELECTED_LOG" ]] && { err "$(t file_not_found)"; return 1; }
}

log_tail() {
  pick_log_file || { log_menu; return; }
  info "$(t log_ctrlc)"
  tail -f "$SELECTED_LOG"
  log_menu
}

log_errors() {
  header "$(t log_errors_title)"
  pick_log_file || { log_menu; return; }
  prompt_input n "$(t prompt_num_lines)" "50"
  echo ""
  { grep -E " [45][0-9]{2} " "$SELECTED_LOG" || true; } | tail -n "$n" | awk '{print $1,$7,$9}' | column -t || true
  pause_prompt; log_menu
}

log_top_ips() {
  header "$(t log_top_ips_title)"
  pick_log_file || { log_menu; return; }
  prompt_input n "$(t prompt_num_ips)" "20"
  echo ""
  local max_count
  max_count=$(awk '{print $1}' "$SELECTED_LOG" | sort | uniq -c | sort -rn | head -1 | awk '{print $1}' || true)
  max_count="${max_count:-1}"
  awk '{print $1}' "$SELECTED_LOG" | sort | uniq -c | sort -rn | head -n "$n" | \
    while read -r count ip; do
      printf "    %-6s %-18s %s\n" "$count" "$ip" "$(draw_bar "$count" "$max_count" 20)"
    done || true
  pause_prompt; log_menu
}

log_status_codes() {
  header "$(t log_status_title)"
  pick_log_file || { log_menu; return; }
  echo ""
  local total
  total=$(wc -l < "$SELECTED_LOG")
  (( total == 0 )) && total=1
  awk '{print $9}' "$SELECTED_LOG" | { grep -E '^[0-9]+$' || true; } | sort | uniq -c | sort -rn | \
    while read -r count code; do
      local color="$NC"
      case "${code:0:1}" in
        2) color="$GREEN" ;; 3) color="$YELLOW" ;; 4) color="$RED" ;; 5) color="$MAGENTA" ;;
      esac
      local bar
      bar=$(draw_bar "$count" "$total" 20)
      printf "    ${color}%-4s${NC} %-8s %s\n" "$code" "$count" "$bar"
    done || true
  pause_prompt; log_menu
}

log_top_urls() {
  header "$(t log_top_urls_title)"
  pick_log_file || { log_menu; return; }
  prompt_input n "$(t prompt_num_urls)" "20"
  echo ""
  awk '{print $7}' "$SELECTED_LOG" | sort | uniq -c | sort -rn | head -n "$n" | column -t || true
  pause_prompt; log_menu
}

log_bandwidth() {
  header "$(t log_bw_title)"
  pick_log_file || { log_menu; return; }
  echo ""
  awk -v lbl="$(t log_total)" '{sum+=$10} END{printf "    " lbl "\n",sum/1024/1024}' "$SELECTED_LOG"
  pause_prompt; log_menu
}

log_sizes() {
  header "$(t log_sizes_title)"
  echo ""
  du -sh "$NGINX_LOG_DIR"/*.log 2>/dev/null | sort -rh | column -t || info "$(t log_no_file)"
  pause_prompt; log_menu
}

# Tarih Aralığı Filtresi
log_date_filter() {
  header "$(t log_date_title)"
  pick_log_file || { log_menu; return; }

  prompt_input start_date "$(t prompt_start_date)" || { log_menu; return; }
  prompt_input end_date "$(t prompt_end_date)" || { log_menu; return; }
  echo ""

  local start_epoch end_epoch
  start_epoch=$(date -d "$(echo "$start_date" | sed 's|/| |g')" +%s 2>/dev/null || echo 0)
  end_epoch=$(date -d "$(echo "$end_date" | sed 's|/| |g')" +%s 2>/dev/null || echo 0)

  if (( start_epoch == 0 || end_epoch == 0 )); then
    awk -v start="$start_date" -v end="$end_date" '
      $4 >= "["start && $4 <= "["end {print}
    ' "$SELECTED_LOG" | tail -100
  else
    awk -v start="$start_date" -v end="$end_date" '
      match($4, /\[([^]]+)/, m) {
        if (m[1] >= start && m[1] <= end) print
      }
    ' "$SELECTED_LOG" | tail -100
  fi

  echo ""
  info "$(t log_last_lines)"
  pause_prompt; log_menu
}

# Log Dışa Aktarma
log_export() {
  header "$(t log_export_title)"
  pick_log_file || { log_menu; return; }

  echo ""
  draw_top
  draw_row "  ${WHITE}1${NC}  CSV"
  draw_row "  ${WHITE}2${NC}  JSON"
  draw_bottom
  draw_prompt
  read -r fmt

  prompt_input outfile "$(t prompt_output_file)" "/tmp/nginx-export"

  case "$fmt" in
    1)
      outfile="${outfile}.csv"
      echo "ip,date,method,url,status,size,referer,user_agent" > "$outfile"
      awk '{
        gsub(/\[/, "", $4);
        gsub(/\]/, "", $5);
        gsub(/"/, "", $6);
        gsub(/"/, "", $7);
        printf "%s,%s %s,%s,%s,%s,%s\n", $1, $4, $5, $6, $7, $9, $10
      }' "$SELECTED_LOG" >> "$outfile"
      log "$(t log_exported_csv "$outfile")"
      ;;
    2)
      outfile="${outfile}.json"
      echo "[" > "$outfile"
      awk 'BEGIN{first=1} {
        gsub(/\[/, "", $4);
        gsub(/\]/, "", $5);
        gsub(/"/, "", $6);
        gsub(/"/, "", $7);
        if (!first) printf ",\n" >> "'"$outfile"'";
        printf "  {\"ip\":\"%s\",\"date\":\"%s %s\",\"method\":\"%s\",\"url\":\"%s\",\"status\":\"%s\",\"size\":\"%s\"}", $1, $4, $5, $6, $7, $9, $10;
        first=0
      }' "$SELECTED_LOG" >> "$outfile"
      echo -e "\n]" >> "$outfile"
      log "$(t log_exported_json "$outfile")"
      ;;
    *) warn "$(t log_invalid_fmt)"; log_menu; return ;;
  esac

  pause_prompt; log_menu
}

# HEALTH CHECK & SERVİS YÖNETİMİ
health_menu() {
  clear
  echo ""
  draw_banner
  header "$(t health_title)"
  draw_top
  draw_row "  ${WHITE}1${NC}  $(t health_status)"
  draw_row "  ${WHITE}2${NC}  $(t health_svc_ctrl)"
  draw_row "  ${WHITE}3${NC}  $(t health_ports)"
  draw_separator
  draw_row "  ${WHITE}4${NC}  $(t health_procs)"
  draw_row "  ${WHITE}5${NC}  $(t health_url_test)"
  draw_row "  ${WHITE}6${NC}  $(t health_bulk_test)"
  draw_separator
  draw_row "  ${WHITE}7${NC}  $(t health_cron)"
  draw_bottom
  draw_footer
  draw_prompt
  read -r choice
  case "$choice" in
    1) health_status ;; 2) health_service_ctrl ;; 3) health_ports ;;
    4) health_procs ;; 5) health_url_test ;; 6) health_bulk_test ;;
    7) health_cron ;;
    0) main_menu ;; q|Q) echo -e "\n  ${GREEN}$(t goodbye)${NC}\n"; exit 0 ;;
    *) warn "$(t invalid_choice)"; health_menu ;;
  esac
}

health_status() {
  header "$(t health_status_title)"
  case "$SERVICE_CMD" in
    systemctl)       systemctl status nginx --no-pager 2>/dev/null || true ;;
    "brew services") brew services list 2>/dev/null | grep nginx || true ;;
    rc-service)      rc-service nginx status 2>/dev/null || true ;;
    *)               service nginx status 2>/dev/null || true ;;
  esac
  pause_prompt; health_menu
}

health_service_ctrl() {
  header "$(t health_svc_title)"; require_root
  echo ""
  draw_top
  draw_row "  ${WHITE}1${NC}  $(t svc_start)"
  draw_row "  ${WHITE}2${NC}  $(t svc_stop)"
  draw_row "  ${WHITE}3${NC}  $(t svc_restart)"
  draw_row "  ${WHITE}4${NC}  $(t svc_reload)"
  draw_bottom
  draw_prompt
  read -r action
  case "$action" in
    1) svc start nginx   && log "$(t svc_started)"      || err "$(t svc_start_fail)" ;;
    2) svc stop nginx    && log "$(t svc_stopped)"       || err "$(t svc_stop_fail)" ;;
    3) svc restart nginx && log "$(t svc_restarted)"     || err "$(t svc_restart_fail)" ;;
    4) nginx -t && svc reload nginx && log "$(t svc_reloaded)" || err "$(t svc_reload_fail)" ;;
    *) warn "$(t invalid_choice)" ;;
  esac
  pause_prompt; health_menu
}

health_ports() {
  header "$(t health_ports_title)"
  echo ""
  if command -v ss &>/dev/null; then
    { ss -tlnp 2>/dev/null || true; } | grep nginx || echo "    $(t nginx_not_listening)"
  elif command -v netstat &>/dev/null; then
    { netstat -tlnp 2>/dev/null || true; } | grep nginx || echo "    $(t nginx_not_listening)"
  else
    warn "$(t no_ss_netstat)"
  fi
  echo ""
  for port in 80 443; do
    if (ss -tlnp 2>/dev/null; netstat -tlnp 2>/dev/null) 2>/dev/null | grep -q ":$port "; then
      echo -e "    ${GREEN}●${NC}  Port $port: ${GREEN}$(t port_open)${NC}"
    else
      echo -e "    ${RED}○${NC}  Port $port: ${RED}$(t port_closed)${NC}"
    fi
  done
  pause_prompt; health_menu
}

health_procs() {
  header "$(t health_procs_title)"
  master=$(pgrep -c -f "nginx: master" 2>/dev/null || echo 0)
  workers=$(pgrep -c -f "nginx: worker" 2>/dev/null || echo 0)
  echo ""
  draw_top
  draw_row "  ${DIM}Master${NC}   ${GREEN}${master}${NC}"
  draw_row "  ${DIM}Workers${NC}  ${GREEN}${workers}${NC}"
  draw_bottom
  echo ""
  ps aux | grep nginx | grep -v grep | awk '{printf "    PID %-8s  CPU %-6s  MEM %-6s\n",$2,$3,$4}' || true
  pause_prompt; health_menu
}

health_url_test() {
  header "$(t health_url_title)"
  command -v curl &>/dev/null || { err "$(t no_curl)"; health_menu; return; }
  prompt_input url "$(t prompt_test_url)" || { health_menu; return; }
  echo ""
  response=$(curl -o /dev/null -s -w "%{http_code}|%{time_total}|%{size_download}" \
    --connect-timeout 10 --max-time 30 "$url" 2>/dev/null)
  http_code=$(echo "$response" | cut -d'|' -f1)
  time_ms=$(echo "$response"  | cut -d'|' -f2)
  size=$(echo "$response"     | cut -d'|' -f3)

  draw_top
  local status_text
  if [[ "$http_code" =~ ^2 ]]; then status_text="${GREEN}$http_code ✓${NC}"
  elif [[ "$http_code" =~ ^3 ]]; then status_text="${YELLOW}$http_code ($(t redirect))${NC}"
  else status_text="${RED}$http_code ✗${NC}"; fi
  draw_row "  ${DIM}$(t col_http)${NC}    $status_text"
  draw_row "  ${DIM}$(t col_time)${NC}    ${time_ms}s"
  draw_row "  ${DIM}$(t col_size)${NC}   ${size} bytes"
  draw_bottom
  pause_prompt; health_menu
}

# Toplu URL Testi
health_bulk_test() {
  header "$(t health_bulk_title)"
  command -v curl &>/dev/null || { err "$(t no_curl)"; health_menu; return; }

  prompt_input url_input "$(t prompt_url_list)" || { health_menu; return; }

  local urls=()
  if [[ -f "$url_input" ]]; then
    mapfile -t urls < "$url_input"
  else
    IFS=',' read -ra urls <<< "$url_input"
  fi

  [[ ${#urls[@]} -eq 0 ]] && { warn "$(t no_url)"; health_menu; return; }

  echo ""
  draw_top
  draw_row "  ${BOLD}${WHITE}$(printf '%-28s %-6s %-8s' "$(t col_url)" "$(t col_http)" "$(t col_time)")${NC}"
  draw_separator

  local max_time=0
  declare -A results
  for url in "${urls[@]}"; do
    url=$(echo "$url" | tr -d '[:space:]')
    [[ -z "$url" ]] && continue
    response=$(curl -o /dev/null -s -w "%{http_code}|%{time_total}" \
      --connect-timeout 5 --max-time 15 "$url" 2>/dev/null || echo "000|0")
    http_code=$(echo "$response" | cut -d'|' -f1)
    time_s=$(echo "$response" | cut -d'|' -f2)

    local color status_icon
    if [[ "$http_code" =~ ^2 ]]; then color="$GREEN"; status_icon="✓"
    elif [[ "$http_code" =~ ^3 ]]; then color="$YELLOW"; status_icon="→"
    else color="$RED"; status_icon="✗"; fi

    local short_url="$url"
    (( ${#short_url} > 28 )) && short_url="${short_url:0:25}..."
    draw_row "  $(printf '%-28s' "$short_url") ${color}$(printf '%-6s' "$http_code$status_icon")${NC} ${time_s}s"
  done
  draw_bottom

  pause_prompt; health_menu
}

health_cron() {
  header "$(t health_cron_title)"; require_root
  if [[ "$OS_FAMILY" == "macos" ]]; then
    warn "$(t health_cron_macos)"; health_menu; return
  fi
  HEALTH_SCRIPT="/usr/local/bin/nginx-health-check.sh"
  cat > "$HEALTH_SCRIPT" <<HEOF
#!/usr/bin/env bash
LOGFILE="/var/log/nginx-health.log"
TS=\$(date '+%Y-%m-%d %H:%M:%S')
SVC_CMD="${SERVICE_CMD}"
is_active() {
  case "\$SVC_CMD" in
    systemctl) systemctl is-active --quiet nginx 2>/dev/null ;;
    rc-service) rc-service nginx status 2>/dev/null | grep -q started ;;
    *) service nginx status &>/dev/null ;;
  esac
}
if ! is_active; then
  echo "[\$TS] WARN: Nginx durdu, yeniden başlatılıyor..." >> "\$LOGFILE"
  case "\$SVC_CMD" in
    systemctl) systemctl start nginx ;;
    rc-service) rc-service nginx start ;;
    *) service nginx start ;;
  esac
  is_active && echo "[\$TS] OK: Yeniden başlatıldı." >> "\$LOGFILE" \
            || echo "[\$TS] ERR: Başlatılamadı!" >> "\$LOGFILE"
else
  echo "[\$TS] OK: Nginx çalışıyor." >> "\$LOGFILE"
fi
HEOF
  chmod +x "$HEALTH_SCRIPT"
  if [[ "$OS_FAMILY" == "alpine" ]]; then
    echo "*/5  *  *  *  *  root  $HEALTH_SCRIPT" >> /etc/crontabs/root
    rc-service crond restart 2>/dev/null || true
  else
    echo "*/5 * * * * root $HEALTH_SCRIPT" > /etc/cron.d/nginx-health
    chmod 644 /etc/cron.d/nginx-health
  fi
  log "$(t health_cron_set)"
  log "Script: $HEALTH_SCRIPT"
  pause_prompt; health_menu
}

# BACKUP / RESTORE
backup_menu() {
  clear
  echo ""
  draw_banner
  header "$(t backup_title)"
  draw_top
  draw_row "  ${WHITE}1${NC}  $(t backup_create)"
  draw_row "  ${WHITE}2${NC}  $(t backup_restore)"
  draw_row "  ${WHITE}3${NC}  $(t backup_list)"
  draw_row "  ${WHITE}4${NC}  $(t backup_cleanup)"
  draw_bottom
  draw_footer
  draw_prompt
  read -r choice
  case "$choice" in
    1) backup_create ;; 2) backup_restore ;; 3) backup_list ;; 4) backup_cleanup ;;
    0) main_menu ;; q|Q) echo -e "\n  ${GREEN}$(t goodbye)${NC}\n"; exit 0 ;;
    *) warn "$(t invalid_choice)"; backup_menu ;;
  esac
}

backup_create() {
  header "$(t backup_create_title)"; require_root
  mkdir -p "$BACKUP_DIR"
  local backup_name="nginx-backup-$(date '+%Y%m%d-%H%M%S').tar.gz"
  local backup_path="$BACKUP_DIR/$backup_name"

  local dirs_to_backup=()
  [[ -d "$NGINX_SITES_AVAILABLE" ]] && dirs_to_backup+=("$NGINX_SITES_AVAILABLE")
  [[ -d "$NGINX_SITES_ENABLED" && "$NGINX_SITES_AVAILABLE" != "$NGINX_SITES_ENABLED" ]] && dirs_to_backup+=("$NGINX_SITES_ENABLED")
  [[ -f "$NGINX_CONF" ]] && dirs_to_backup+=("$NGINX_CONF")
  [[ -d "/etc/nginx/ssl" ]] && dirs_to_backup+=("/etc/nginx/ssl")

  if [[ ${#dirs_to_backup[@]} -eq 0 ]]; then
    err "$(t backup_no_config)"
    pause_prompt; backup_menu; return
  fi

  tar -czf "$backup_path" "${dirs_to_backup[@]}" 2>/dev/null \
    && log "$(t backup_created "$backup_path")" \
    || err "$(t backup_failed)"

  local size
  size=$(du -sh "$backup_path" 2>/dev/null | awk '{print $1}')
  echo ""
  draw_top
  draw_row "  ${DIM}$(t col_file)${NC}   $backup_name"
  draw_row "  ${DIM}$(t col_size)${NC}   $size"
  draw_row "  ${DIM}Konum${NC}   $BACKUP_DIR"
  draw_bottom

  pause_prompt; backup_menu
}

backup_restore() {
  header "$(t backup_restore_title)"; require_root
  mapfile -t backups < <(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null)
  if [[ ${#backups[@]} -eq 0 ]]; then
    warn "$(t backup_no_found): $BACKUP_DIR"
    pause_prompt; backup_menu; return
  fi

  echo ""
  for i in "${!backups[@]}"; do
    local bname bsize
    bname=$(basename "${backups[$i]}")
    bsize=$(du -sh "${backups[$i]}" 2>/dev/null | awk '{print $1}')
    echo -e "    ${WHITE}$((i+1))${NC}  $bname ${DIM}($bsize)${NC}"
  done
  echo ""
  prompt_input num "$(t prompt_backup_num)" || { backup_menu; return; }
  validate_index "$num" "${#backups[@]}" || { warn "$(t invalid_choice)"; pause_prompt; backup_menu; return; }
  local selected="${backups[$((num-1))]}"
  [[ ! -f "$selected" ]] && { err "$(t backup_no_found)"; pause_prompt; backup_menu; return; }

  echo ""
  warn "$(t backup_overwrite_warn)"
  echo -ne "  $(t confirm_continue) ${DIM}[${MSG[confirm_no_default]}]${NC}: "; read -r confirm
  [[ "${confirm,,}" != "${MSG[confirm_yes_char]}" ]] && { backup_menu; return; }

  local auto_backup="$BACKUP_DIR/pre-restore-$(date '+%Y%m%d-%H%M%S').tar.gz"
  tar -czf "$auto_backup" "$NGINX_CONF" "$NGINX_SITES_AVAILABLE" 2>/dev/null || true
  info "$(t backup_auto_saved "$(basename "$auto_backup")")"

  tar -xzf "$selected" -C / 2>/dev/null \
    && log "$(t backup_restored)" \
    || { err "$(t backup_restore_fail)"; pause_prompt; backup_menu; return; }

  nginx -t && svc reload nginx && log "$(t config_reloaded)" || warn "$(t backup_config_bad)"
  pause_prompt; backup_menu
}

backup_list() {
  header "$(t backup_list_title)"
  mapfile -t backups < <(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null)
  if [[ ${#backups[@]} -eq 0 ]]; then
    warn "$(t backup_no_found)"; pause_prompt; backup_menu; return
  fi

  echo ""
  draw_top
  draw_row "  ${BOLD}${WHITE}$(printf '%-30s %-8s %s' "$(t col_file)" "$(t col_size)" "$(t col_date)")${NC}"
  draw_separator
  for backup in "${backups[@]}"; do
    local bname bsize bdate
    bname=$(basename "$backup")
    bsize=$(du -sh "$backup" 2>/dev/null | awk '{print $1}')
    bdate=$(stat -c '%y' "$backup" 2>/dev/null | cut -d. -f1 || stat -f '%Sm' "$backup" 2>/dev/null || echo "?")
    draw_row "  $(printf '%-30s %-8s' "$bname" "$bsize")${DIM}$bdate${NC}"
  done
  draw_bottom

  pause_prompt; backup_menu
}

backup_cleanup() {
  header "$(t backup_cleanup_title)"; require_root
  prompt_input days "$(t prompt_cleanup_days)" "30"

  local count
  count=$(find "$BACKUP_DIR" -name "*.tar.gz" -mtime +"$days" 2>/dev/null | wc -l)

  if (( count == 0 )); then
    info "$days $(t backup_none_old)"
  else
    info "$(t backup_found_old "$count")"
    echo -ne "  $(t confirm_delete) ${DIM}[${MSG[confirm_no_default]}]${NC}: "; read -r confirm
    if [[ "${confirm,,}" == "${MSG[confirm_yes_char]}" ]]; then
      find "$BACKUP_DIR" -name "*.tar.gz" -mtime +"$days" -delete 2>/dev/null
      log "$(t backup_deleted "$count")"
    fi
  fi

  pause_prompt; backup_menu
}

# GÜVENLİK TARAMASI
security_menu() {
  clear
  echo ""
  draw_banner
  header "$(t security_title)"
  draw_top
  draw_row "  ${WHITE}1${NC}  $(t security_full)"
  draw_row "  ${WHITE}2${NC}  $(t security_headers)"
  draw_row "  ${WHITE}3${NC}  $(t security_ssl_config)"
  draw_row "  ${WHITE}4${NC}  $(t security_dir_listing)"
  draw_row "  ${WHITE}5${NC}  $(t security_sensitive)"
  draw_bottom
  draw_footer
  draw_prompt
  read -r choice
  case "$choice" in
    1) security_full_scan ;; 2) security_headers ;; 3) security_ssl_config ;;
    4) security_directory_listing ;; 5) security_sensitive_files ;;
    0) main_menu ;; q|Q) echo -e "\n  ${GREEN}$(t goodbye)${NC}\n"; exit 0 ;;
    *) warn "$(t invalid_choice)"; security_menu ;;
  esac
}

security_check_item() {
  local label="$1" status="$2"
  if [[ "$status" == "pass" ]]; then
    echo -e "    ${GREEN}✓${NC}  $label"
  elif [[ "$status" == "warn" ]]; then
    echo -e "    ${YELLOW}!${NC}  $label"
  else
    echo -e "    ${RED}✗${NC}  $label"
  fi
}

security_full_scan() {
  header "$(t security_full_title)"
  info "$(t security_scanning)"
  echo ""

  local score=0 total=0

  # 1. server_tokens
  total=$((total + 1))
  if grep -rq "server_tokens\s*off" /etc/nginx/ 2>/dev/null; then
    security_check_item "server_tokens off (Versiyon gizleme)" "pass"
    score=$((score + 1))
  else
    security_check_item "server_tokens off ayarlanmamış" "fail"
  fi

  # 2. X-Frame-Options
  total=$((total + 1))
  if grep -rq "X-Frame-Options" /etc/nginx/ 2>/dev/null; then
    security_check_item "X-Frame-Options header'ı mevcut" "pass"
    score=$((score + 1))
  else
    security_check_item "X-Frame-Options header'ı eksik" "fail"
  fi

  # 3. X-Content-Type-Options
  total=$((total + 1))
  if grep -rq "X-Content-Type-Options" /etc/nginx/ 2>/dev/null; then
    security_check_item "X-Content-Type-Options header'ı mevcut" "pass"
    score=$((score + 1))
  else
    security_check_item "X-Content-Type-Options header'ı eksik" "fail"
  fi

  # 4. X-XSS-Protection
  total=$((total + 1))
  if grep -rq "X-XSS-Protection" /etc/nginx/ 2>/dev/null; then
    security_check_item "X-XSS-Protection header'ı mevcut" "pass"
    score=$((score + 1))
  else
    security_check_item "X-XSS-Protection header'ı eksik" "warn"
  fi

  # 5. Content-Security-Policy
  total=$((total + 1))
  if grep -rq "Content-Security-Policy" /etc/nginx/ 2>/dev/null; then
    security_check_item "Content-Security-Policy mevcut" "pass"
    score=$((score + 1))
  else
    security_check_item "Content-Security-Policy eksik" "warn"
  fi

  # 6. autoindex off
  total=$((total + 1))
  if grep -rq "autoindex\s*on" /etc/nginx/ 2>/dev/null; then
    security_check_item "autoindex on bulundu (dizin listeleme açık!)" "fail"
  else
    security_check_item "Dizin listeleme kapalı" "pass"
    score=$((score + 1))
  fi

  # 7. SSL protokolleri
  total=$((total + 1))
  if grep -rq "ssl_protocols" /etc/nginx/ 2>/dev/null; then
    if grep -rq "SSLv3\|TLSv1\b\|TLSv1.0\b" /etc/nginx/ 2>/dev/null; then
      security_check_item "Güvensiz SSL protokolü aktif (SSLv3/TLSv1)" "fail"
    else
      security_check_item "SSL protokolleri güvenli" "pass"
      score=$((score + 1))
    fi
  else
    security_check_item "ssl_protocols tanımlanmamış" "warn"
  fi

  # 8. client_max_body_size
  total=$((total + 1))
  if grep -rq "client_max_body_size" /etc/nginx/ 2>/dev/null; then
    security_check_item "client_max_body_size ayarlı" "pass"
    score=$((score + 1))
  else
    security_check_item "client_max_body_size varsayılan (1MB)" "warn"
  fi

  # 9. .git / .env erişimi
  total=$((total + 1))
  if grep -rqE "location.*\.(git|env|htpasswd)" /etc/nginx/ 2>/dev/null; then
    security_check_item "Hassas dosya erişim kuralları mevcut" "pass"
    score=$((score + 1))
  else
    security_check_item ".git/.env erişim engeli tanımlı değil" "fail"
  fi

  # 10. default_server
  total=$((total + 1))
  if grep -rq "default_server" /etc/nginx/ 2>/dev/null; then
    security_check_item "default_server tanımlı" "pass"
    score=$((score + 1))
  else
    security_check_item "default_server tanımsız" "warn"
  fi

  echo ""
  (( total == 0 )) && total=1
  local pct=$((score * 100 / total))
  local color
  if (( pct >= 80 )); then color=$GREEN
  elif (( pct >= 50 )); then color=$YELLOW
  else color=$RED; fi

  draw_top
  draw_row_center "${BOLD}${color}$(t security_score "$score" "$total" "$pct")${NC}"
  draw_row_center "$(draw_bar $score $total 30)"
  draw_bottom

  pause_prompt; security_menu
}

security_headers() {
  header "$(t security_headers_title)"
  prompt_input url "$(t prompt_security_url)" || { security_menu; return; }
  echo ""

  local headers
  headers=$(curl -sI --connect-timeout 10 --max-time 15 "$url" 2>/dev/null)

  local checks=(
    "X-Frame-Options"
    "X-Content-Type-Options"
    "X-XSS-Protection"
    "Content-Security-Policy"
    "Strict-Transport-Security"
    "Referrer-Policy"
    "Permissions-Policy"
  )

  for h in "${checks[@]}"; do
    if echo "$headers" | grep -qi "$h"; then
      local val
      val=$(echo "$headers" | grep -i "$h" | head -1 | cut -d: -f2- | xargs)
      security_check_item "$h: ${DIM}$val${NC}" "pass"
    else
      security_check_item "$h $(t security_missing)" "fail"
    fi
  done

  # Server header
  echo ""
  if echo "$headers" | grep -qi "^Server:"; then
    local srv
    srv=$(echo "$headers" | grep -i "^Server:" | head -1 | cut -d: -f2- | xargs)
    security_check_item "$(t security_server_open "${DIM}$srv${NC}")" "warn"
  else
    security_check_item "$(t security_server_hidden)" "pass"
  fi

  pause_prompt; security_menu
}

security_ssl_config() {
  header "$(t security_ssl_title)"
  echo ""

  if ! grep -rq "ssl_protocols" /etc/nginx/ 2>/dev/null; then
    warn "$(t security_no_ssl_proto)"
  else
    local protos
    protos=$(grep -rh "ssl_protocols" /etc/nginx/ 2>/dev/null | head -1 | sed 's/.*ssl_protocols//' | tr -d ';' || true)
    info "$(t security_protocols "$protos")"

    echo "$protos" | grep -q "SSLv3" && security_check_item "SSLv3 aktif (güvensiz!)" "fail" || true
    echo "$protos" | grep -q "TLSv1\b\|TLSv1.0\b" && security_check_item "TLSv1.0 aktif (güvensiz!)" "fail" || true
    echo "$protos" | grep -q "TLSv1.1" && security_check_item "TLSv1.1 aktif (önerilmez)" "warn" || true
    echo "$protos" | grep -q "TLSv1.2" && security_check_item "TLSv1.2 aktif" "pass" || true
    echo "$protos" | grep -q "TLSv1.3" && security_check_item "TLSv1.3 aktif" "pass" || true
  fi

  echo ""
  if grep -rq "ssl_prefer_server_ciphers" /etc/nginx/ 2>/dev/null; then
    security_check_item "ssl_prefer_server_ciphers ayarlı" "pass"
  else
    security_check_item "ssl_prefer_server_ciphers ayarlanmamış" "warn"
  fi

  if grep -rq "ssl_session_tickets\s*off" /etc/nginx/ 2>/dev/null; then
    security_check_item "ssl_session_tickets off" "pass"
  else
    security_check_item "ssl_session_tickets kapatılmamış" "warn"
  fi

  if grep -rq "ssl_stapling\s*on" /etc/nginx/ 2>/dev/null; then
    security_check_item "OCSP Stapling aktif" "pass"
  else
    security_check_item "OCSP Stapling kapalı" "warn"
  fi

  pause_prompt; security_menu
}

security_directory_listing() {
  header "$(t security_dir_title)"
  echo ""

  if grep -rn "autoindex\s*on" /etc/nginx/ 2>/dev/null; then
    err "$(t security_autoindex_found)"
    echo ""
    grep -rn "autoindex\s*on" /etc/nginx/ 2>/dev/null | while read -r line; do
      echo -e "    ${RED}●${NC}  $line"
    done || true
  else
    log "$(t security_autoindex_clean)"
  fi

  pause_prompt; security_menu
}

security_sensitive_files() {
  header "$(t security_sensitive_title)"
  echo ""
  info "$(t security_checking)"
  echo ""

  local patterns=(".git" ".env" ".htpasswd" ".htaccess" "wp-config.php" ".svn" ".DS_Store")
  local has_rule=false

  for pat in "${patterns[@]}"; do
    if grep -r "$pat" /etc/nginx/ 2>/dev/null | grep -q "deny\|return 403\|return 404"; then
      security_check_item "$pat $(t security_blocked)" "pass"
      has_rule=true
    else
      security_check_item "$pat $(t security_not_blocked)" "fail"
    fi
  done

  if [[ "$has_rule" == "false" ]]; then
    echo ""
    info "$(t security_suggestion)"
    echo ""
    echo -e "    ${DIM}location ~ /\\.(git|env|htpasswd|svn|DS_Store) {${NC}"
    echo -e "    ${DIM}    deny all;${NC}"
    echo -e "    ${DIM}    return 404;${NC}"
    echo -e "    ${DIM}}${NC}"
  fi

  pause_prompt; security_menu
}

# REVERSE PROXY
proxy_menu() {
  clear
  echo ""
  draw_banner
  header "$(t proxy_title)"
  draw_top
  draw_row "  ${WHITE}1${NC}  $(t proxy_create)"
  draw_row "  ${WHITE}2${NC}  $(t proxy_ws)"
  draw_row "  ${WHITE}3${NC}  $(t proxy_lb)"
  draw_row "  ${WHITE}4${NC}  $(t proxy_list)"
  draw_bottom
  draw_footer
  draw_prompt
  read -r choice
  case "$choice" in
    1) proxy_create ;; 2) proxy_websocket ;; 3) proxy_loadbalancer ;;
    4) proxy_list ;;
    0) main_menu ;; q|Q) echo -e "\n  ${GREEN}$(t goodbye)${NC}\n"; exit 0 ;;
    *) warn "$(t invalid_choice)"; proxy_menu ;;
  esac
}

proxy_write_config() {
  local domain="$1" content="$2"
  if [[ "$OS_FAMILY" == "rhel" || "$OS_FAMILY" == "alpine" ]]; then
    mkdir -p "$NGINX_SITES_AVAILABLE"
    echo "$content" > "$NGINX_SITES_AVAILABLE/${domain}.conf"
  else
    mkdir -p "$NGINX_SITES_AVAILABLE"
    echo "$content" > "$NGINX_SITES_AVAILABLE/$domain"
    if [[ "$OS_FAMILY" == "debian" || "$OS_FAMILY" == "arch" ]]; then
      mkdir -p "$NGINX_SITES_ENABLED"
      ln -sf "$NGINX_SITES_AVAILABLE/$domain" "$NGINX_SITES_ENABLED/$domain"
    fi
  fi
}

proxy_create() {
  header "$(t proxy_create_title)"; require_root
  prompt_input domain "$(t prompt_domain)" || { proxy_menu; return; }
  prompt_input backend "$(t prompt_backend)" || { proxy_menu; return; }
  prompt_input port "$(t prompt_listen_port)" "80"

  local conf
  conf=$(cat <<PROXY
server {
    listen $port;
    listen [::]:$port;
    server_name $domain www.$domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;

    location / {
        proxy_pass http://$backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
PROXY
  )

  proxy_write_config "$domain" "$conf"
  nginx -t && svc reload nginx && log "$(t proxy_created "$domain" "$backend")" \
    || err "$(t config_error)"
  pause_prompt; proxy_menu
}

proxy_websocket() {
  header "$(t proxy_ws_title)"; require_root
  prompt_input domain "$(t prompt_domain)" || { proxy_menu; return; }
  prompt_input backend "$(t prompt_backend_ws)" || { proxy_menu; return; }
  prompt_input ws_path "$(t prompt_ws_path)" "/ws"
  prompt_input port "$(t prompt_listen_port)" "80"

  local conf
  conf=$(cat <<WSPROXY
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen $port;
    listen [::]:$port;
    server_name $domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;

    location $ws_path {
        proxy_pass http://$backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location / {
        proxy_pass http://$backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
WSPROXY
  )

  proxy_write_config "$domain" "$conf"
  nginx -t && svc reload nginx && log "$(t proxy_ws_created "$domain" "$backend")" \
    || err "$(t config_error)"
  pause_prompt; proxy_menu
}

proxy_loadbalancer() {
  header "$(t proxy_lb_title)"; require_root
  prompt_input domain "$(t prompt_domain)" || { proxy_menu; return; }
  prompt_input port "$(t prompt_listen_port)" "80"
  echo ""
  prompt_input method "$(t prompt_lb_method)" "1"

  local method_str=""
  case "$method" in
    2) method_str="    least_conn;" ;;
    3) method_str="    ip_hash;" ;;
  esac

  echo ""
  info "$(t lb_enter_backends)"
  local backends=()
  while true; do
    echo -ne "    $(t prompt_lb_backend): "; read -r b
    [[ -z "$b" ]] && break
    backends+=("$b")
  done

  [[ ${#backends[@]} -eq 0 ]] && { warn "$(t lb_no_backend)"; proxy_menu; return; }

  local upstream_name="${domain//./_}_pool"
  local upstream_block="upstream $upstream_name {\n"
  [[ -n "$method_str" ]] && upstream_block+="$method_str\n"
  for b in "${backends[@]}"; do
    upstream_block+="    server $b;\n"
  done
  upstream_block+="}"

  local conf
  conf=$(echo -e "$upstream_block

server {
    listen $port;
    listen [::]:$port;
    server_name $domain;
    access_log ${NGINX_LOG_DIR}/${domain}_access.log;
    error_log  ${NGINX_LOG_DIR}/${domain}_error.log;

    location / {
        proxy_pass http://$upstream_name;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}")

  proxy_write_config "$domain" "$conf"
  nginx -t && svc reload nginx && log "$(t proxy_lb_created "$domain" "${#backends[@]}")" \
    || err "$(t config_error)"
  pause_prompt; proxy_menu
}

proxy_list() {
  header "$(t proxy_list_title)"
  echo ""

  local found=false
  for conf_file in "$NGINX_SITES_AVAILABLE"/*; do
    [[ -f "$conf_file" ]] || continue
    if grep -q "proxy_pass" "$conf_file" 2>/dev/null; then
      local name backend
      name=$(basename "$conf_file")
      backend=$(grep "proxy_pass" "$conf_file" | head -1 | awk '{print $2}' | tr -d ';')
      echo -e "    ${GREEN}●${NC}  $name ${DIM}-> $backend${NC}"
      found=true
    fi
  done

  [[ "$found" == "false" ]] && info "$(t proxy_not_found)"
  pause_prompt; proxy_menu
}

# RATE LIMIT / IP ENGELLEME
firewall_menu() {
  clear
  echo ""
  draw_banner
  header "$(t fw_title)"
  draw_top
  draw_row "  ${WHITE}1${NC}  $(t fw_rate_limit)"
  draw_row "  ${WHITE}2${NC}  $(t fw_block_ip)"
  draw_row "  ${WHITE}3${NC}  $(t fw_unblock_ip)"
  draw_row "  ${WHITE}4${NC}  $(t fw_list_blocked)"
  draw_row "  ${WHITE}5${NC}  $(t fw_geoip)"
  draw_bottom
  draw_footer
  draw_prompt
  read -r choice
  case "$choice" in
    1) fw_rate_limit ;; 2) fw_block_ip ;; 3) fw_unblock_ip ;;
    4) fw_list_blocked ;; 5) fw_geoip ;;
    0) main_menu ;; q|Q) echo -e "\n  ${GREEN}$(t goodbye)${NC}\n"; exit 0 ;;
    *) warn "$(t invalid_choice)"; firewall_menu ;;
  esac
}

fw_rate_limit() {
  header "$(t fw_rate_title)"; require_root
  prompt_input zone "$(t prompt_zone)" "limitzone"
  prompt_input rate "$(t prompt_rate)" "10r/s"
  prompt_input burst "$(t prompt_burst)" "20"

  local limit_conf="/etc/nginx/conf.d/rate-limit.conf"
  cat > "$limit_conf" <<RATELIMIT
# Rate Limiting - nginx-manager tarafından oluşturuldu
limit_req_zone \$binary_remote_addr zone=${zone}:10m rate=${rate};

# Kullanım: server bloğunuzda şunu ekleyin:
#   location / {
#       limit_req zone=${zone} burst=${burst} nodelay;
#   }
RATELIMIT

  log "$(t fw_rate_created "$limit_conf")"
  echo ""
  info "$(t fw_rate_add_note)"
  echo ""
  echo -e "    ${DIM}limit_req zone=${zone} burst=${burst} nodelay;${NC}"

  nginx -t && svc reload nginx || warn "$(t config_error)"
  pause_prompt; firewall_menu
}

fw_block_ip() {
  header "$(t fw_block_title)"; require_root
  prompt_input ip "$(t prompt_block_ip)" || { firewall_menu; return; }

  local block_conf="/etc/nginx/conf.d/blocked-ips.conf"
  if [[ ! -f "$block_conf" ]]; then
    cat > "$block_conf" <<BLOCKHEADER
# Engelli IP'ler - nginx-manager tarafından yönetilir
# Bu dosyayı nginx.conf veya server bloğunda include edin
# Kullanım: include /etc/nginx/conf.d/blocked-ips.conf;
BLOCKHEADER
  fi

  if grep -q "deny $ip;" "$block_conf" 2>/dev/null; then
    warn "$(t fw_ip_already "$ip")"
  else
    echo "deny $ip;" >> "$block_conf"
    log "$(t fw_ip_blocked "$ip")"
  fi

  nginx -t && svc reload nginx || warn "$(t config_error)"
  pause_prompt; firewall_menu
}

fw_unblock_ip() {
  header "$(t fw_unblock_title)"; require_root
  local block_conf="/etc/nginx/conf.d/blocked-ips.conf"

  if [[ ! -f "$block_conf" ]]; then
    warn "$(t fw_no_blocked)"; pause_prompt; firewall_menu; return
  fi

  mapfile -t blocked < <(grep "^deny" "$block_conf" 2>/dev/null | awk '{print $2}' | tr -d ';')
  if [[ ${#blocked[@]} -eq 0 ]]; then
    warn "$(t fw_no_blocked_ip)"; pause_prompt; firewall_menu; return
  fi

  echo ""
  for i in "${!blocked[@]}"; do
    echo -e "    ${WHITE}$((i+1))${NC}  ${blocked[$i]}"
  done
  echo ""
  prompt_input num "$(t prompt_unblock_num)" || { firewall_menu; return; }
  validate_index "$num" "${#blocked[@]}" || { warn "$(t invalid_number)"; pause_prompt; firewall_menu; return; }
  local ip="${blocked[$((num-1))]}"

  sed -i "/deny $ip;/d" "$block_conf" 2>/dev/null || \
    sed -i '' "/deny $ip;/d" "$block_conf" 2>/dev/null
  log "$(t fw_ip_unblocked "$ip")"

  nginx -t && svc reload nginx || warn "$(t config_error)"
  pause_prompt; firewall_menu
}

fw_list_blocked() {
  header "$(t fw_list_title)"
  local block_conf="/etc/nginx/conf.d/blocked-ips.conf"

  if [[ ! -f "$block_conf" ]]; then
    warn "$(t fw_no_blocked)"; pause_prompt; firewall_menu; return
  fi

  echo ""
  local count=0
  grep "^deny" "$block_conf" 2>/dev/null | while read -r line; do
    local ip
    ip=$(echo "$line" | awk '{print $2}' | tr -d ';')
    echo -e "    ${RED}●${NC}  $ip"
    count=$((count + 1))
  done || true

  local total
  total=$(grep -c "^deny" "$block_conf" 2>/dev/null || echo 0)
  echo ""
  info "$(t fw_total_blocked "$total")"
  pause_prompt; firewall_menu
}

fw_geoip() {
  header "$(t fw_geoip_title)"; require_root
  info "$(t fw_geoip_note)"
  echo ""
  warn "$(t fw_geoip_warn)"
  echo ""
  prompt_input countries "$(t prompt_countries)" || { firewall_menu; return; }

  local geoip_conf="/etc/nginx/conf.d/geoip-block.conf"
  cat > "$geoip_conf" <<GEOIP
# GeoIP Ülke Engelleme - nginx-manager tarafından oluşturuldu
# GeoIP2 veritabanı yolu ayarlanmalıdır
#
# geoip2 /usr/share/GeoIP/GeoLite2-Country.mmdb {
#     auto_reload 60m;
#     \$geoip2_data_country_code country iso_code;
# }
#
# map \$geoip2_data_country_code \$blocked_country {
#     default 0;
GEOIP

  IFS=',' read -ra codes <<< "$countries"
  for code in "${codes[@]}"; do
    code=$(echo "$code" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    echo "#     $code 1;" >> "$geoip_conf"
  done

  cat >> "$geoip_conf" <<'GEOIP2'
# }
#
# Kullanım (server bloğunda):
#   if ($blocked_country) { return 403; }
GEOIP2

  log "$(t fw_geoip_created "$geoip_conf")"
  info "$(t fw_geoip_edit)"
  info "$(t fw_geoip_db)"
  pause_prompt; firewall_menu
}

# NGİNX KURULUM
install_menu() {
  clear
  echo ""
  draw_banner
  header "$(t install_title)"

  if nginx_installed; then
    local ver
    ver=$(nginx -v 2>&1 | awk -F/ '{print $2}')
    draw_top
    draw_row "  ${GREEN}●${NC}  $(t install_already) ${DIM}(v$ver)${NC}"
    draw_bottom
    echo ""
    draw_top
    draw_row "  ${WHITE}1${NC}  $(t install_reinstall)"
    draw_row "  ${WHITE}2${NC}  $(t install_remove)"
    draw_bottom
  else
    draw_top
    draw_row "  ${RED}●${NC}  $(t install_not)"
    draw_bottom
    echo ""
    draw_top
    draw_row "  ${WHITE}1${NC}  $(t install_now)"
    draw_bottom
  fi
  draw_footer
  draw_prompt
  read -r choice
  case "$choice" in
    1) install_nginx ;; 2) uninstall_nginx ;;
    0) main_menu ;; q|Q) echo -e "\n  ${GREEN}$(t goodbye)${NC}\n"; exit 0 ;;
    *) warn "$(t invalid_choice)"; install_menu ;;
  esac
}

install_nginx() {
  header "$(t install_title_do)"; require_root
  info "$(t install_updating)"
  $PKG_UPDATE 2>/dev/null || true

  info "$(t install_installing)"
  $PKG_INSTALL nginx 2>/dev/null \
    && log "$(t install_done)" \
    || { err "$(t install_failed)"; pause_prompt; install_menu; return; }

  # sites-available/enabled dizinleri oluştur
  if [[ "$OS_FAMILY" == "debian" || "$OS_FAMILY" == "arch" ]]; then
    mkdir -p "$NGINX_SITES_AVAILABLE" "$NGINX_SITES_ENABLED"
  fi

  svc start nginx 2>/dev/null && log "$(t install_done)" || warn "$(t svc_start_fail)"

  # Otomatik başlatma
  case "$SERVICE_CMD" in
    systemctl) systemctl enable nginx 2>/dev/null && log "$(t install_autostart)" || true ;;
    rc-service) rc-update add nginx default 2>/dev/null && log "$(t install_autostart)" || true ;;
    *) true ;;
  esac

  local ver
  ver=$(nginx -v 2>&1 | awk -F/ '{print $2}')
  echo ""
  draw_top
  draw_row "  ${DIM}Versiyon${NC}  $ver"
  draw_row "  ${DIM}Config${NC}   $NGINX_CONF"
  draw_row "  ${DIM}Log${NC}      $NGINX_LOG_DIR"
  draw_bottom

  pause_prompt; install_menu
}

uninstall_nginx() {
  header "$(t install_remove_title)"; require_root

  warn "$(t install_warn)"
  echo -ne "  $(t confirm_continue) ${DIM}[${MSG[confirm_no_default]}]${NC}: "; read -r confirm
  [[ "${confirm,,}" != "${MSG[confirm_yes_char]}" ]] && { install_menu; return; }

  echo -ne "  $(t install_purge) ${DIM}[${MSG[confirm_no_default]}]${NC}: "; read -r purge

  svc stop nginx 2>/dev/null

  case "$OS_FAMILY" in
    debian)
      if [[ "${purge,,}" == "${MSG[confirm_yes_char]}" ]]; then
        apt-get purge -y nginx nginx-common 2>/dev/null
      else
        apt-get remove -y nginx 2>/dev/null
      fi
      ;;
    rhel)    dnf remove -y nginx 2>/dev/null || yum remove -y nginx 2>/dev/null ;;
    arch)    pacman -Rns --noconfirm nginx 2>/dev/null ;;
    alpine)  apk del nginx 2>/dev/null ;;
    macos)   brew uninstall nginx 2>/dev/null ;;
  esac

  log "$(t install_removed)"
  pause_prompt; install_menu
}

# ANA MENÜ
main_menu() {
  clear
  echo ""
  draw_banner

  # Durum çubuğu
  draw_top
  draw_row "  ${DIM}OS${NC}       ${CYAN}${OS_ID^} — $(os_label)${NC}"
  if nginx_installed; then
    local ver
    ver=$(nginx -v 2>&1 | awk -F/ '{print $2}')
    if svc_is_active; then
      draw_row "  ${DIM}Nginx${NC}    ${GREEN}● $(t status_running)${NC} ${DIM}(v$ver)${NC}"
    else
      draw_row "  ${DIM}Nginx${NC}    ${RED}● $(t status_stopped)${NC} ${DIM}(v$ver)${NC}"
    fi
  else
    draw_row "  ${DIM}Nginx${NC}    ${RED}● $(t status_not_installed)${NC}"
  fi

  # SSL uyarısı
  CERT_DIR="/etc/letsencrypt/live"
  [[ "$OS_FAMILY" == "macos" ]] && CERT_DIR="/usr/local/etc/letsencrypt/live"
  if [[ -d "$CERT_DIR" ]]; then
    for cert_path in "$CERT_DIR"/*/cert.pem; do
      [[ -f "$cert_path" ]] || continue
      expiry=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
      days_left=$(( ($(date_to_epoch "$expiry") - $(date +%s)) / 86400 ))
      domain=$(basename "$(dirname "$cert_path")")
      if (( days_left <= 14 )); then
        draw_row "  ${RED}⚠ $(t ssl_days_left "$domain" "$days_left")${NC}"
      fi
    done
  fi
  draw_bottom

  echo ""

  # MODÜLLER
  draw_top
  draw_row_center "${BOLD}${WHITE}$(t modules)${NC}"
  draw_separator
  draw_empty
  draw_row "  ${WHITE}1${NC}   $(t mod_config)"
  draw_row "  ${WHITE}2${NC}   $(t mod_ssl)"
  draw_row "  ${WHITE}3${NC}   $(t mod_log)"
  draw_row "  ${WHITE}4${NC}   $(t mod_health)"
  draw_empty
  draw_separator
  draw_empty
  draw_row "  ${WHITE}5${NC}   $(t mod_backup)"
  draw_row "  ${WHITE}6${NC}   $(t mod_security)"
  draw_row "  ${WHITE}7${NC}   $(t mod_proxy)"
  draw_row "  ${WHITE}8${NC}   $(t mod_firewall)"
  draw_empty
  draw_separator
  draw_row "  ${WHITE}9${NC}   $(t mod_install)"
  draw_row "  ${DIM}s${NC}   $(t mod_os_change)"
  draw_bottom
  draw_main_footer
  draw_prompt
  read -r choice
  case "$choice" in
    1) config_menu ;; 2) ssl_menu ;; 3) log_menu ;; 4) health_menu ;;
    5) backup_menu ;; 6) security_menu ;; 7) proxy_menu ;; 8) firewall_menu ;;
    9) install_menu ;;
    s|S) os_select_menu; main_menu ;;
    0|q|Q) echo -e "\n  ${GREEN}$(t goodbye)${NC}\n"; exit 0 ;;
    *) warn "$(t invalid_choice)"; main_menu ;;
  esac
}

#  KOMUT SATIRI ARGÜMANLARI
cli_usage() {
  echo ""
  echo -e "${BOLD}$(t cli_usage):${NC} $0 [options]"
  echo ""
  echo -e "  ${WHITE}--health${NC}          $(t cli_health)"
  echo -e "  ${WHITE}--test${NC}            $(t cli_test)"
  echo -e "  ${WHITE}--reload${NC}          $(t cli_reload)"
  echo -e "  ${WHITE}--restart${NC}         $(t cli_restart)"
  echo -e "  ${WHITE}--status${NC}          $(t cli_status)"
  echo -e "  ${WHITE}--backup${NC}          $(t cli_backup)"
  echo -e "  ${WHITE}--ssl-check${NC}       $(t cli_ssl_check)"
  echo -e "  ${WHITE}--security-scan${NC}   $(t cli_security)"
  echo -e "  ${WHITE}--list-sites${NC}      $(t cli_list_sites)"
  echo -e "  ${WHITE}--block-ip IP${NC}     $(t cli_block)"
  echo -e "  ${WHITE}--unblock-ip IP${NC}   $(t cli_unblock)"
  echo -e "  ${WHITE}--export FORMAT${NC}   $(t cli_export)"
  echo -e "  ${WHITE}--install${NC}         $(t cli_install)"
  echo -e "  ${WHITE}--lang CODE${NC}       $(t cli_lang)"
  echo -e "  ${WHITE}--help${NC}            $(t cli_help)"
  echo ""
  exit 0
}

cli_detect_os() {
  detect_os || {
    err "OS algılanamadı. Lütfen interaktif modda çalıştırın."
    exit 1
  }
}

if [[ $# -gt 0 ]]; then
  CLI_MODE=true
  case "$1" in
    --lang)
      LANG_CODE="${2:-tr}"; init_lang; shift 2
      [[ $# -eq 0 ]] && { os_init; main_menu; exit 0; }
      ;;
    --help|-h)
      cli_usage
      ;;
    --health)
      cli_detect_os
      echo -ne "Nginx: "
      if nginx_installed; then
        svc_is_active && echo -e "${GREEN}$(t status_running)${NC}" || echo -e "${RED}$(t status_stopped)${NC}"
        nginx -v 2>&1
      else
        echo -e "${RED}$(t status_not_installed)${NC}"
      fi
      ;;
    --test)
      nginx -t || { echo "$(t config_error)"; exit 1; }
      ;;
    --reload)
      cli_detect_os
      nginx -t && svc reload nginx && echo -e "${GREEN}$(t config_reloaded)${NC}" || echo -e "${RED}$(t config_error)${NC}"
      ;;
    --restart)
      cli_detect_os
      svc restart nginx && echo -e "${GREEN}$(t config_reloaded)${NC}" || echo -e "${RED}$(t config_error)${NC}"
      ;;
    --status)
      cli_detect_os
      case "$SERVICE_CMD" in
        systemctl) systemctl status nginx --no-pager || true ;;
        *) svc_is_active && echo "$(t status_running)" || echo "$(t status_stopped)" ;;
      esac
      ;;
    --backup)
      cli_detect_os
      mkdir -p "$BACKUP_DIR"
      local_name="nginx-backup-$(date '+%Y%m%d-%H%M%S').tar.gz"
      tar -czf "$BACKUP_DIR/$local_name" "$NGINX_CONF" "$NGINX_SITES_AVAILABLE" 2>/dev/null \
        && echo -e "${GREEN}$(t backup_created "$BACKUP_DIR/$local_name")${NC}" \
        || echo -e "${RED}$(t backup_failed)${NC}"
      ;;
    --ssl-check)
      cli_detect_os
      CERT_DIR="/etc/letsencrypt/live"
      [[ "$OS_FAMILY" == "macos" ]] && CERT_DIR="/usr/local/etc/letsencrypt/live"
      if [[ ! -d "$CERT_DIR" ]]; then
        echo "$(t ssl_no_cert)"; exit 1
      fi
      printf "%-30s %-25s %s\n" "$(t col_domain)" "$(t col_expiry)" "$(t col_remaining)"
      echo "──────────────────────────────────────────────────────"
      for cert_path in "$CERT_DIR"/*/cert.pem; do
        [[ -f "$cert_path" ]] || continue
        domain=$(basename "$(dirname "$cert_path")")
        expiry=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
        expiry_epoch=$(date_to_epoch "$expiry")
        days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))
        printf "%-30s %-25s %s\n" "$domain" "$expiry" "$(t unit_days "$days_left")"
      done
      ;;
    --security-scan)
      cli_detect_os
      echo "=== $(t cli_security) ==="
      echo ""
      cli_score=0; cli_total=0

      cli_total=$((cli_total+1))
      grep -rq "server_tokens\s*off" /etc/nginx/ 2>/dev/null \
        && { echo "[PASS] server_tokens off"; cli_score=$((cli_score+1)); } \
        || echo "[FAIL] server_tokens off"

      cli_total=$((cli_total+1))
      grep -rq "X-Frame-Options" /etc/nginx/ 2>/dev/null \
        && { echo "[PASS] X-Frame-Options"; cli_score=$((cli_score+1)); } \
        || echo "[FAIL] X-Frame-Options"

      cli_total=$((cli_total+1))
      grep -rq "X-Content-Type-Options" /etc/nginx/ 2>/dev/null \
        && { echo "[PASS] X-Content-Type-Options"; cli_score=$((cli_score+1)); } \
        || echo "[FAIL] X-Content-Type-Options"

      cli_total=$((cli_total+1))
      if grep -rq "autoindex\s*on" /etc/nginx/ 2>/dev/null; then
        echo "[FAIL] autoindex on"
      else
        echo "[PASS] autoindex"
        cli_score=$((cli_score+1))
      fi

      cli_total=$((cli_total+1))
      if grep -rq "SSLv3\|TLSv1\b" /etc/nginx/ 2>/dev/null; then
        echo "[FAIL] SSL/TLS"
      else
        echo "[PASS] SSL/TLS"
        cli_score=$((cli_score+1))
      fi

      echo ""
      echo "$(t security_score "$cli_score" "$cli_total" "$(( cli_score * 100 / cli_total ))")"
      ;;
    --list-sites)
      cli_detect_os
      if [[ "$OS_FAMILY" == "debian" || "$OS_FAMILY" == "arch" ]]; then
        ls "$NGINX_SITES_AVAILABLE" 2>/dev/null | while read -r site; do
          if [[ -L "$NGINX_SITES_ENABLED/$site" ]]; then
            echo "[$(t active)]  $site"
          else
            echo "[$(t inactive)]  $site"
          fi
        done || echo "$(t no_site_found)"
      else
        ls "$NGINX_SITES_AVAILABLE"/*.conf 2>/dev/null | while read -r f; do
          echo "[$(t active)]  $(basename "$f")"
        done || echo "$(t no_site_found)"
      fi
      ;;
    --block-ip)
      cli_detect_os
      [[ -z "${2:-}" ]] && { echo "$(t cli_usage): $0 --block-ip IP"; exit 1; }
      block_conf="/etc/nginx/conf.d/blocked-ips.conf"
      [[ ! -f "$block_conf" ]] && echo "# Blocked IPs" > "$block_conf"
      echo "deny $2;" >> "$block_conf"
      nginx -t && svc reload nginx && echo -e "${GREEN}$(t fw_ip_blocked "$2")${NC}" || echo -e "${RED}$(t config_error)${NC}"
      ;;
    --unblock-ip)
      cli_detect_os
      [[ -z "${2:-}" ]] && { echo "$(t cli_usage): $0 --unblock-ip IP"; exit 1; }
      block_conf="/etc/nginx/conf.d/blocked-ips.conf"
      sed -i "/deny $2;/d" "$block_conf" 2>/dev/null || sed -i '' "/deny $2;/d" "$block_conf" 2>/dev/null || true
      nginx -t && svc reload nginx && echo -e "${GREEN}$(t fw_ip_unblocked "$2")${NC}" || echo -e "${RED}$(t config_error)${NC}"
      ;;
    --export)
      cli_detect_os
      format="${2:-csv}"
      outfile="/tmp/nginx-export-$(date '+%Y%m%d-%H%M%S').$format"
      access_log="$NGINX_LOG_DIR/access.log"
      [[ ! -f "$access_log" ]] && { echo "$(t log_no_file)"; exit 1; }
      if [[ "$format" == "csv" ]]; then
        echo "ip,date,method,url,status,size" > "$outfile"
        awk '{gsub(/\[/,"",$4); printf "%s,%s,%s,%s,%s,%s\n",$1,$4,$6,$7,$9,$10}' "$access_log" >> "$outfile"
      elif [[ "$format" == "json" ]]; then
        echo "[" > "$outfile"
        awk 'BEGIN{f=1}{gsub(/\[/,"",$4);if(!f)printf ",\n";printf "  {\"ip\":\"%s\",\"date\":\"%s\",\"method\":\"%s\",\"url\":\"%s\",\"status\":\"%s\",\"size\":\"%s\"}",$1,$4,$6,$7,$9,$10;f=0}' "$access_log" >> "$outfile"
        echo -e "\n]" >> "$outfile"
      else
        echo "$(t log_invalid_fmt)"; exit 1
      fi
      echo "$(t log_exported_csv "$outfile")"
      ;;
    --install)
      cli_detect_os
      $PKG_UPDATE 2>/dev/null || true
      $PKG_INSTALL nginx && echo -e "${GREEN}$(t install_done)${NC}" || echo -e "${RED}$(t install_failed)${NC}"
      ;;
    *)
      echo "$(t invalid_choice): $1"
      cli_usage
      ;;
  esac
  exit 0
fi

os_init
main_menu
