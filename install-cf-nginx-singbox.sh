#!/usr/bin/env bash
# Cloudflare → Nginx → sing-box (VLESS + HTTPUpgrade) installer.
#
# This installer owns one Nginx virtual host and one loopback-only sing-box
# service.  It intentionally does not alter an existing direct-443 sing-box
# deployment: migrating a live direct node needs an explicit decision because
# both designs require TCP port 443.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly APP_NAME='cf-nginx-singbox'
readonly CONFIG_DIR='/etc/sing-box-cf-nginx'
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly STATE_FILE="$CONFIG_DIR/credentials.env"
readonly CLIENT_DIR="$CONFIG_DIR/client-profiles"
readonly QR_DIR="$CONFIG_DIR/qr"
readonly SERVICE_FILE='/etc/systemd/system/sing-box-cf-nginx.service'
readonly SETTINGS_DIR='/etc/cf-nginx-singbox'
readonly SETTINGS_FILE="$SETTINGS_DIR/settings"
readonly SYNC_SCRIPT='/usr/local/sbin/cf-nginx-singbox-sync'
readonly SYNC_SERVICE='/etc/systemd/system/cf-nginx-singbox-sync.service'
readonly SYNC_TIMER='/etc/systemd/system/cf-nginx-singbox-sync.timer'
readonly CERT_RENEW_SCRIPT='/usr/local/sbin/cf-nginx-singbox-renew-certificates'
readonly CERT_RENEW_SERVICE='/etc/systemd/system/cf-nginx-singbox-cert-renew.service'
readonly CERT_RENEW_TIMER='/etc/systemd/system/cf-nginx-singbox-cert-renew.timer'
readonly WARP_HEALTH_PORT=18080
readonly WARP_HEALTH_SCRIPT='/usr/local/sbin/cf-nginx-singbox-warp-healthcheck'
readonly WARP_HEALTH_SERVICE='/etc/systemd/system/cf-nginx-singbox-warp-health.service'
readonly WARP_HEALTH_TIMER='/etc/systemd/system/cf-nginx-singbox-warp-health.timer'
readonly FAIL2BAN_JAIL_NAME='cf-nginx-singbox-sshd'
readonly FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/$FAIL2BAN_JAIL_NAME.conf"
readonly NGINX_SITE_NAME='cf-nginx-singbox'
readonly NGINX_AVAILABLE="/etc/nginx/sites-available/$NGINX_SITE_NAME.conf"
readonly NGINX_ENABLED="/etc/nginx/sites-enabled/$NGINX_SITE_NAME.conf"
readonly CF_ACCESS_CONF='/etc/nginx/conf.d/00-cf-nginx-singbox-origin-access.conf'
readonly WEB_ROOT='/var/www/cf-nginx-singbox'
readonly SITE_REPO_DIR='/opt/cf-nginx-singbox-site-content'
readonly DEFAULT_SITE_REPOSITORY_URL='https://github.com/xik54/nginx-site-content.git'
readonly DEFAULT_BRANCH='main'
readonly SINGBOX_APT_KEYRING='/etc/apt/keyrings/sagernet.asc'
readonly SINGBOX_APT_REPOSITORY='/etc/apt/sources.list.d/sagernet.sources'
readonly LOOPBACK_PORT=10000
readonly BACKUP_PORT=8443
readonly BACKUP_SNI='www.speedtest.net'
readonly WARP_PROXY_PORT=40000

DOMAIN=''
VPS_IP=''
SITE_REPOSITORY_URL="$DEFAULT_SITE_REPOSITORY_URL"
BRANCH="$DEFAULT_BRANCH"
BRANCH_EXPLICIT=0
FORCE=0
PREFLIGHT_ONLY=0
HEALTH_CHECK_ONLY=0
SHOW_CLIENT_ARTIFACTS_ONLY=0
WITH_WARP_UPSTREAM=0
WARP_SETTING_EXPLICIT=0
SKIP_CERTBOT=0

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo bash install-cf-nginx-singbox.sh --domain YOUR_DOMAIN --ip YOUR_VPS_IPV4

Required:
  --domain DOMAIN          Cloudflare-proxied hostname used by the website and VLESS.
  --ip IPV4                Public IPv4 address of this VPS. It is checked against
                           the address observed from the VPS; it is not exposed in
                           the generated client profile.

Optional:
  --site-repository URL    Public Git repository containing site/ or dist/.
                           Default: https://github.com/xik54/nginx-site-content.git
  --branch NAME            Website branch (default: repository default branch).
  --with-warp-upstream     Route proxy egress through official warp-cli SOCKS5.
  --without-warp-upstream  Keep proxy egress direct when updating an existing
                           installation that previously enabled WARP.
  --skip-certbot           Do not request/renew a Let's Encrypt certificate.
                           Useful only for a controlled dry-run or pre-staged cert.
  --preflight              Detect conflicting services and validate inputs only.
  --health-check           Validate an already-installed deployment. Domain and IP
                           are read from its root-only credentials file.
  --show-client-artifacts  Render both node QR codes in this SSH terminal and
                           print secure client-JSON download paths. Does not
                           change services or credentials.
  --force                  Replace this installer's own files, or take over a
                           conflicting Nginx virtual host for --domain after making
                           timestamped backups. It never overwrites another process
                           already listening on TCP 443.
  -h, --help               Show this help.

Before running:
  1. Create the DNS record for DOMAIN in Cloudflare and turn the orange cloud on.
  2. Point the record at this VPS IPv4 address.
  3. Allow inbound TCP 80, 443, and 8443 in the VPS provider firewall/security group.

The script generates a UUID and an unguessable HTTPUpgrade path. Credentials are
stored only under /etc/sing-box-cf-nginx with mode 0600. It also creates a
separate direct VLESS + REALITY + Vision fallback on TCP 8443, with its own UUID
and QR code; that fallback does not depend on Nginx or Cloudflare.
EOF
}

while (($#)); do
  case "$1" in
    --domain) [[ ${2:-} ]] || die '--domain needs a value.'; DOMAIN="$2"; shift 2 ;;
    --ip) [[ ${2:-} ]] || die '--ip needs a value.'; VPS_IP="$2"; shift 2 ;;
    --site-repository) [[ ${2:-} ]] || die '--site-repository needs a value.'; SITE_REPOSITORY_URL="$2"; shift 2 ;;
    --branch) [[ ${2:-} ]] || die '--branch needs a value.'; BRANCH="$2"; BRANCH_EXPLICIT=1; shift 2 ;;
    --with-warp-upstream) WITH_WARP_UPSTREAM=1; WARP_SETTING_EXPLICIT=1; shift ;;
    --without-warp-upstream) WITH_WARP_UPSTREAM=0; WARP_SETTING_EXPLICIT=1; shift ;;
    --skip-certbot) SKIP_CERTBOT=1; shift ;;
    --preflight) PREFLIGHT_ONLY=1; shift ;;
    --health-check) HEALTH_CHECK_ONLY=1; shift ;;
    --show-client-artifacts) SHOW_CLIENT_ARTIFACTS_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

valid_domain() {
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [[ $1 != *..* ]] && [[ $1 == *.* ]]
}

valid_ipv4() {
  local IFS='.' octet
  read -r -a octet <<< "$1"
  ((${#octet[@]} == 4)) || return 1
  for value in "${octet[@]}"; do
    [[ $value =~ ^[0-9]+$ ]] && ((10#$value <= 255)) || return 1
  done
}

require_supported_host() {
  [[ $EUID -eq 0 ]] || die 'Run as root, for example: sudo bash install-cf-nginx-singbox.sh ...'
  [[ $(uname -s) == Linux ]] || die 'This installer runs on a Linux VPS only.'
  command -v systemctl >/dev/null || die 'systemd is required.'
  [[ -d /run/systemd/system ]] || die 'systemd is not running; containers are unsupported.'
  [[ -r /etc/os-release ]] || die 'Could not identify this Linux distribution.'
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == ubuntu || ${ID:-} == debian ]] || die 'This installer currently supports Ubuntu and Debian only.'
  command -v apt-get >/dev/null || die 'apt-get is required on this host.'
}

validate_inputs() {
  valid_domain "$DOMAIN" || die '--domain must be one complete hostname.'
  valid_ipv4 "$VPS_IP" || die '--ip must be a valid public IPv4 address.'
  [[ $BRANCH =~ ^[A-Za-z0-9._/-]+$ ]] || die '--branch contains unsupported characters.'
  [[ $SITE_REPOSITORY_URL =~ ^https://[^[:space:]]+$ ]] || die '--site-repository must be an HTTPS URL.'
}

resolve_site_branch() {
  # An explicit --branch always wins. Otherwise follow the repository's
  # symbolic HEAD, so both main and master remain a two-input installation.
  if (( BRANCH_EXPLICIT )); then
    git ls-remote --exit-code --heads "$SITE_REPOSITORY_URL" "refs/heads/$BRANCH" >/dev/null 2>&1 \
      || die "Cannot read branch '$BRANCH' from $SITE_REPOSITORY_URL. Ensure the repository and branch are public and reachable."
    return 0
  fi

  local remote_default_branch
  remote_default_branch="$(git ls-remote --symref "$SITE_REPOSITORY_URL" HEAD 2>/dev/null \
    | awk '$1 == "ref:" && $2 ~ /^refs\/heads\// && $3 == "HEAD" {sub(/^refs\/heads\//, "", $2); print $2; exit}')"

  [[ "$remote_default_branch" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Cannot determine the default branch for $SITE_REPOSITORY_URL. Ensure the repository is reachable and public, or pass --branch explicitly."
  BRANCH="$remote_default_branch"
  info "Using website repository default branch: $BRANCH"
}

restore_saved_warp_selection() {
  local saved_setting
  (( WARP_SETTING_EXPLICIT )) && return 0
  [[ -r $STATE_FILE ]] || return 0
  # The credentials file is generated by this root-only installer; use its saved
  # preference so a routine --force update never silently removes WARP routing.
  saved_setting="$(sed -n "s/^WARP_UPSTREAM_ENABLED='\([01]\)'$/\1/p" "$STATE_FILE" | head -n1)"
  [[ $saved_setting == 0 || $saved_setting == 1 ]] && WITH_WARP_UPSTREAM="$saved_setting"
}

configure_warp_apt_repository() {
  command -v curl >/dev/null || die 'curl is required to configure the official Cloudflare WARP repository.'
  command -v gpg >/dev/null || die 'gpg is required to configure the official Cloudflare WARP repository.'
  command -v lsb_release >/dev/null || die 'lsb_release is required to configure the official Cloudflare WARP repository.'
  local codename
  codename="$(lsb_release -cs)"
  [[ $codename =~ ^[a-z0-9]+$ ]] || die "Unsupported apt distribution codename for WARP: $codename"
  curl -fsSL --proto '=https' --tlsv1.2 https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor --yes --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  chmod 0644 /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' "$codename" \
    > /etc/apt/sources.list.d/cloudflare-client.list
}

repair_existing_warp_apt_repository() {
  (( WITH_WARP_UPSTREAM )) || return 0
  [[ -e /etc/apt/sources.list.d/cloudflare-client.list ]] || return 0
  if ! command -v curl >/dev/null || ! command -v gpg >/dev/null || ! command -v lsb_release >/dev/null; then
    warn 'An existing Cloudflare WARP APT source was found but its key cannot be refreshed before apt update because curl, gpg, or lsb_release is unavailable.'
    return 0
  fi
  info 'Refreshing the existing Cloudflare WARP APT signing key before apt update'
  configure_warp_apt_repository
}

install_packages() {
  info 'Installing Nginx, Certbot, Git, and prerequisite tools'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl openssl git rsync nginx certbot iproute2 qrencode
  if ! apt-get install -y --no-install-recommends fail2ban; then
    warn 'Fail2Ban could not be installed from this VPS package source; SSH protection was skipped without affecting the proxy deployment.'
  fi
}

install_sing_box() {
  info 'Installing current stable sing-box from its official signed package repository'
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --proto '=https' --tlsv1.2 https://sing-box.app/gpg.key -o "$SINGBOX_APT_KEYRING" \
    || die 'Could not download the official sing-box package signing key.'
  chmod 0644 "$SINGBOX_APT_KEYRING"
  cat > "$SINGBOX_APT_REPOSITORY" <<EOF
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: $SINGBOX_APT_KEYRING
EOF
  apt-get update -y
  apt-get install -y sing-box
  command -v sing-box >/dev/null || die 'sing-box was installed but is not available in PATH.'
}

get_observed_public_ipv4() {
  local endpoint candidate
  for endpoint in 'https://api.ipify.org' 'https://ifconfig.me/ip' 'https://ipv4.icanhazip.com'; do
    candidate="$(curl -4fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    if valid_ipv4 "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

check_vps_address() {
  local observed
  observed="$(get_observed_public_ipv4 || true)"
  [[ -n $observed ]] || die 'Could not determine this VPS public IPv4. Check outbound HTTPS and retry.'
  [[ $observed == "$VPS_IP" ]] || die "--ip is $VPS_IP, but this VPS reports $observed. Refusing to issue a certificate or configure the wrong host."
}

show_domain_resolution() {
  local addresses
  addresses="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  [[ -n $addresses ]] || die "$DOMAIN has no public IPv4 DNS response yet. Create the Cloudflare DNS record first."
  info "$DOMAIN currently resolves to: $addresses"
}

listener_rows() {
  local port="$1"
  ss -H -ltnp "sport = :$port" 2>/dev/null || true
}

assert_listener_is_safe() {
  local port="$1" rows
  rows="$(listener_rows "$port")"
  [[ -z $rows ]] && return 0
  if [[ $rows == *'nginx'* ]]; then
    return 0
  fi
  die "TCP $port is already owned by a non-Nginx process: $rows\nThe Cloudflare/Nginx design requires Nginx to own TCP 80 and 443. Existing services were left unchanged."
}

domain_already_claimed() {
  command -v nginx >/dev/null || return 1
  nginx -T 2>/dev/null \
    | awk -v domain="$DOMAIN" '
      $1 == "server_name" {
        for (i = 2; i <= NF; i++) {
          value = $i
          sub(/;$/, "", value)
          if (tolower(value) == tolower(domain)) found = 1
        }
      }
      END { exit(found ? 0 : 1) }
    '
}

assert_existing_configuration_is_safe() {
  local existing_loopback existing_backup
  if [[ -e $CONFIG_FILE || -e $STATE_FILE || -e $SERVICE_FILE ]]; then
    (( FORCE )) || die "Existing $APP_NAME artifacts were found. Re-run with --force only if you intend to update this installation."
  fi

  assert_listener_is_safe 80
  assert_listener_is_safe 443
  existing_loopback="$(listener_rows "$LOOPBACK_PORT")"
  if [[ -n $existing_loopback && $existing_loopback != *'sing-box'* ]]; then
    die "The loopback backend port $LOOPBACK_PORT is owned by another process: $existing_loopback"
  fi
  existing_backup="$(listener_rows "$BACKUP_PORT")"
  if [[ -n $existing_backup ]]; then
    if [[ $existing_backup != *'sing-box'* ]]; then
      die "The direct fallback port $BACKUP_PORT is owned by another process: $existing_backup"
    fi
    [[ -e $CONFIG_FILE || -e $STATE_FILE ]] \
      || die "TCP $BACKUP_PORT is already used by a different sing-box deployment. It was left unchanged."
  fi

  if domain_already_claimed && [[ ! -e $NGINX_AVAILABLE ]]; then
    if [[ -f /etc/nginx/sites-available/github-nginx-site.conf ]] && (( FORCE )); then
      : # The known legacy GitHub site is backed up and disabled during migration.
    elif [[ -f /etc/nginx/sites-available/github-nginx-site.conf ]]; then
      die "The legacy GitHub Nginx virtual host already claims $DOMAIN. Re-run with --force to migrate it safely."
    else
      die "An Nginx virtual host outside this installer already claims $DOMAIN. It was not changed because duplicate server_name blocks make routing unpredictable. Choose another domain or remove that vhost deliberately first."
    fi
  fi

  if [[ -f /etc/github-nginx-site/settings ]] \
    && grep -Fqx "SITE_DOMAIN='$DOMAIN'" /etc/github-nginx-site/settings 2>/dev/null; then
    (( FORCE )) || die "The legacy github-nginx-site synchronizer manages $DOMAIN. Re-run with --force to migrate it; the old timer will be disabled after the new site passes validation."
  fi
}

check_warp_reserved_ports() {
  local listener
  (( WITH_WARP_UPSTREAM )) || return 0
  [[ $WARP_PROXY_PORT != "$LOOPBACK_PORT" && $WARP_PROXY_PORT != "$BACKUP_PORT" ]] \
    || die "The WARP SOCKS5 port $WARP_PROXY_PORT conflicts with a sing-box listener."
  [[ $WARP_HEALTH_PORT != "$LOOPBACK_PORT" && $WARP_HEALTH_PORT != "$BACKUP_PORT" ]] \
    || die "The WARP health port $WARP_HEALTH_PORT conflicts with a sing-box listener."

  listener="$(listener_rows "$WARP_PROXY_PORT")"
  if [[ -n $listener && $listener != *'warp-svc'* ]]; then
    die "TCP $WARP_PROXY_PORT is already owned by a process other than warp-svc: $listener"
  fi
  listener="$(listener_rows "$WARP_HEALTH_PORT")"
  if [[ -n $listener && $listener != *'sing-box'* ]]; then
    die "TCP $WARP_HEALTH_PORT is already owned by another process: $listener"
  fi
}

write_cloudflare_origin_access() {
  local v4_ranges v6_ranges range
  v4_ranges="$(curl -fsSL --proto '=https' --tlsv1.2 https://www.cloudflare.com/ips-v4)" \
    || die 'Could not retrieve the official Cloudflare IPv4 network list.'
  v6_ranges="$(curl -fsSL --proto '=https' --tlsv1.2 https://www.cloudflare.com/ips-v6)" \
    || die 'Could not retrieve the official Cloudflare IPv6 network list.'

  {
    cat <<'EOF'
# Generated by cf-nginx-singbox. Do not edit by hand; re-run the installer to
# refresh Cloudflare's published edge ranges. $realip_remote_addr preserves the
# TCP peer even after CF-Connecting-IP becomes the client address.
geo $realip_remote_addr $cf_nginx_singbox_trusted_proxy {
    default 0;
    127.0.0.1/32 1;
    ::1/128 1;
EOF
    while IFS= read -r range; do
      [[ $range =~ ^[0-9.]+/[0-9]+$ ]] && printf '    %s 1;\n' "$range"
    done <<< "$v4_ranges"
    while IFS= read -r range; do
      [[ $range =~ ^[0-9A-Fa-f:]+/[0-9]+$ ]] && printf '    %s 1;\n' "$range"
    done <<< "$v6_ranges"
    cat <<'EOF'
}

set_real_ip_from 127.0.0.1;
set_real_ip_from ::1;
EOF
    while IFS= read -r range; do
      [[ $range =~ ^[0-9.]+/[0-9]+$ ]] && printf 'set_real_ip_from %s;\n' "$range"
    done <<< "$v4_ranges"
    while IFS= read -r range; do
      [[ $range =~ ^[0-9A-Fa-f:]+/[0-9]+$ ]] && printf 'set_real_ip_from %s;\n' "$range"
    done <<< "$v6_ranges"
    cat <<'EOF'
real_ip_header CF-Connecting-IP;
real_ip_recursive on;
EOF
  } > "$CF_ACCESS_CONF.new"
  chmod 0644 "$CF_ACCESS_CONF.new"
  mv -f "$CF_ACCESS_CONF.new" "$CF_ACCESS_CONF"
}

write_site_settings() {
  install -d -m 0700 "$SETTINGS_DIR"
  cat > "$SETTINGS_FILE" <<EOF
# Generated by $APP_NAME. The file is root-readable only.
SITE_REPOSITORY_URL=$(printf '%q' "$SITE_REPOSITORY_URL")
SITE_REPO_DIR=$(printf '%q' "$SITE_REPO_DIR")
WEB_ROOT=$(printf '%q' "$WEB_ROOT")
BRANCH=$(printf '%q' "$BRANCH")
EOF
  chmod 0600 "$SETTINGS_FILE"
}

write_site_sync_script() {
  cat > "$SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Synchronize web content without touching the Nginx virtual host that routes
# VLESS HTTPUpgrade. This runs from a systemd timer created by the installer.
set -Eeuo pipefail
IFS=$'\n\t'

readonly SETTINGS_FILE='/etc/cf-nginx-singbox/settings'
readonly LOCK_FILE='/run/cf-nginx-singbox-sync.lock'

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ -r $SETTINGS_FILE ]] || die "Missing $SETTINGS_FILE"
# shellcheck disable=SC1090
source "$SETTINGS_FILE"

site_source_dir() {
  if [[ -d $SITE_REPO_DIR/site ]]; then
    printf '%s\n' "$SITE_REPO_DIR/site"
  elif [[ -d $SITE_REPO_DIR/dist ]]; then
    printf '%s\n' "$SITE_REPO_DIR/dist"
  else
    die 'Website repository must contain site/ or dist/.'
  fi
}

checkout_site() {
  if [[ -d $SITE_REPO_DIR/.git ]]; then
    git -C "$SITE_REPO_DIR" fetch --quiet origin "$BRANCH"
    git -C "$SITE_REPO_DIR" checkout --quiet --detach "origin/$BRANCH"
  else
    install -d -m 0755 "$(dirname "$SITE_REPO_DIR")"
    git clone --branch "$BRANCH" --single-branch "$SITE_REPOSITORY_URL" "$SITE_REPO_DIR"
    git -C "$SITE_REPO_DIR" checkout --quiet --detach "origin/$BRANCH"
  fi
}

main() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || die 'Another website synchronization is already running.'
  checkout_site

  local revision source staging release
  revision="$(git -C "$SITE_REPO_DIR" rev-parse "origin/$BRANCH")"
  source="$(site_source_dir)"
  staging="$(mktemp -d "$(dirname "$WEB_ROOT")/.cf-nginx-singbox.XXXXXX")"
  trap 'rm -rf "$staging"' EXIT
  rsync -a --delete "$source/" "$staging/"
  [[ -f $staging/index.html ]] || die 'Website build has no index.html.'

  release="$WEB_ROOT/release-$revision"
  rm -rf "$release"
  install -d -m 0755 "$WEB_ROOT"
  mv "$staging" "$release"
  # The installer uses umask 077 and rsync preserves the Git checkout modes.
  # Make the published static tree readable by Nginx without making the
  # repository clone or the root-only credentials directory public.
  chmod -R a+rX "$release"
  ln -sfn "$(basename "$release")" "$WEB_ROOT/.current-next"
  mv -Tf "$WEB_ROOT/.current-next" "$WEB_ROOT/current"
  nginx -t
  systemctl reload nginx
  trap - EXIT
  printf 'Published website revision %s\n' "$revision"
}

main "$@"
EOF
  chmod 0755 "$SYNC_SCRIPT"
}

write_site_units() {
  cat > "$SYNC_SERVICE" <<EOF
[Unit]
Description=Synchronize the $APP_NAME website from GitHub
Wants=network-online.target
After=network-online.target nginx.service

[Service]
Type=oneshot
ExecStart=$SYNC_SCRIPT
EOF
  cat > "$SYNC_TIMER" <<'EOF'
[Unit]
Description=Periodically synchronize the cf-nginx-singbox website

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

write_certificate_renewal() {
  cat > "$CERT_RENEW_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Let Certbot decide whether renewal is due. The deploy hook executes only when
# a certificate was actually renewed, so routine timer runs do not reload Nginx.
set -Eeuo pipefail

certbot renew --quiet --deploy-hook '/usr/sbin/nginx -t && /usr/bin/systemctl reload nginx'
EOF
  chmod 0700 "$CERT_RENEW_SCRIPT"

  cat > "$CERT_RENEW_SERVICE" <<EOF
[Unit]
Description=Renew the $DOMAIN certificate and safely reload Nginx
Wants=network-online.target
After=network-online.target nginx.service

[Service]
Type=oneshot
ExecStart=$CERT_RENEW_SCRIPT
EOF
  cat > "$CERT_RENEW_TIMER" <<'EOF'
[Unit]
Description=Check the cf-nginx-singbox certificate twice each day

[Timer]
OnCalendar=*-*-* 03:17:00
OnCalendar=*-*-* 15:17:00
RandomizedDelaySec=20min
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

state_value() {
  # credentials.env is data, not a shell program. Read only the generated
  # values we need so old state files containing immutable port constants do
  # not attempt to overwrite this script's readonly variables.
  local key="$1"
  sed -n "s/^${key}='\(.*\)'$/\1/p" "$STATE_FILE" | tail -n1
}

load_or_create_credentials() {
  local reality_pair
  if [[ -r $STATE_FILE ]]; then
    DEPLOYED_DOMAIN="$(state_value DEPLOYED_DOMAIN)"
    HTTPUPGRADE_UUID="$(state_value HTTPUPGRADE_UUID)"
    HTTPUPGRADE_PATH="$(state_value HTTPUPGRADE_PATH)"
    BACKUP_UUID="$(state_value BACKUP_UUID)"
    BACKUP_PRIVATE_KEY="$(state_value BACKUP_PRIVATE_KEY)"
    BACKUP_PUBLIC_KEY="$(state_value BACKUP_PUBLIC_KEY)"
    BACKUP_SHORT_ID="$(state_value BACKUP_SHORT_ID)"
    WARP_UPSTREAM_ENABLED="$(state_value WARP_UPSTREAM_ENABLED)"
    [[ $HTTPUPGRADE_UUID && $HTTPUPGRADE_PATH && $DEPLOYED_DOMAIN ]] \
      || die "Existing $STATE_FILE is incomplete; inspect the saved configuration before using --force."
    [[ $DEPLOYED_DOMAIN == "$DOMAIN" ]] \
      || die "Existing credentials belong to $DEPLOYED_DOMAIN, not $DOMAIN. Use a separate VPS or explicitly archive the prior installation."
    HTTPUPGRADE_UUID="$HTTPUPGRADE_UUID"
    HTTPUPGRADE_PATH="$HTTPUPGRADE_PATH"
    if (( ! WARP_SETTING_EXPLICIT )); then
      WITH_WARP_UPSTREAM="${WARP_UPSTREAM_ENABLED:-0}"
    fi
  else
    HTTPUPGRADE_UUID="$(cat /proc/sys/kernel/random/uuid)"
    HTTPUPGRADE_PATH="/$(openssl rand -hex 20)"
  fi

  # Keep the direct fallback credentials independent from the Cloudflare entry.
  # This permits revoking or rotating one node without invalidating the other.
  if [[ -z ${BACKUP_UUID:-} ]]; then BACKUP_UUID="$(cat /proc/sys/kernel/random/uuid)"; fi
  if [[ -z ${BACKUP_SHORT_ID:-} ]]; then BACKUP_SHORT_ID="$(openssl rand -hex 4)"; fi
  if [[ -z ${BACKUP_PRIVATE_KEY:-} || -z ${BACKUP_PUBLIC_KEY:-} ]]; then
    reality_pair="$(sing-box generate reality-keypair)"
    BACKUP_PRIVATE_KEY="$(printf '%s\n' "$reality_pair" | sed -n 's/.*PrivateKey:[[:space:]]*//p' | head -n1)"
    BACKUP_PUBLIC_KEY="$(printf '%s\n' "$reality_pair" | sed -n 's/.*PublicKey:[[:space:]]*//p' | head -n1)"
    [[ -n $BACKUP_PRIVATE_KEY && -n $BACKUP_PUBLIC_KEY ]] \
      || die 'Could not parse the sing-box REALITY keypair for the direct fallback.'
  fi
}

write_singbox_config() {
  local outbound_config='{ "type": "direct", "tag": "direct" }'
  local route_config=''
  local warp_health_inbound=''
  if (( WITH_WARP_UPSTREAM )); then
    outbound_config=$(cat <<EOF
    { "type": "socks", "tag": "warp-cli", "server": "127.0.0.1", "server_port": $WARP_PROXY_PORT, "version": "5" },
    { "type": "direct", "tag": "direct" }
EOF
)
    route_config=', "route": { "final": "warp-cli" }'
    warp_health_inbound=$(cat <<EOF
    {
      "type": "mixed", "tag": "warp-health-local",
      "listen": "127.0.0.1", "listen_port": $WARP_HEALTH_PORT
    },
EOF
)
  fi

  install -d -m 0700 "$CONFIG_DIR"
  cat > "$CONFIG_FILE.new" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
$warp_health_inbound
    {
      "type": "vless",
      "tag": "vless-httpupgrade-loopback",
      "listen": "127.0.0.1",
      "listen_port": $LOOPBACK_PORT,
      "users": [{ "name": "main", "uuid": "$HTTPUPGRADE_UUID" }],
      "transport": {
        "type": "httpupgrade",
        "host": "$DOMAIN",
        "path": "$HTTPUPGRADE_PATH"
      }
    },
    {
      "type": "vless",
      "tag": "vless-reality-direct-backup",
      "listen": "::",
      "listen_port": $BACKUP_PORT,
      "users": [{ "name": "backup", "uuid": "$BACKUP_UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "$BACKUP_SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$BACKUP_SNI", "server_port": 443 },
          "private_key": "$BACKUP_PRIVATE_KEY",
          "short_id": ["$BACKUP_SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    $outbound_config
  ]$route_config
}
EOF
  chmod 0600 "$CONFIG_FILE.new"
  sing-box check -c "$CONFIG_FILE.new" || die 'Generated sing-box configuration is invalid; no configuration was activated.'
  mv -f "$CONFIG_FILE.new" "$CONFIG_FILE"

  # Keep the in-memory state aligned with the new configuration. This matters for
  # --without-warp-upstream, which intentionally leaves warp-svc installed but
  # must remove the sing-box route and its health monitor immediately.
  WARP_UPSTREAM_ENABLED="$WITH_WARP_UPSTREAM"

  cat > "$STATE_FILE" <<EOF
# Generated by $APP_NAME at $(date -Is). Keep this file private.
DEPLOYED_DOMAIN='$DOMAIN'
VPS_IP='$VPS_IP'
HTTPUPGRADE_UUID='$HTTPUPGRADE_UUID'
HTTPUPGRADE_PATH='$HTTPUPGRADE_PATH'
BACKUP_UUID='$BACKUP_UUID'
BACKUP_PRIVATE_KEY='$BACKUP_PRIVATE_KEY'
BACKUP_PUBLIC_KEY='$BACKUP_PUBLIC_KEY'
BACKUP_SHORT_ID='$BACKUP_SHORT_ID'
WARP_UPSTREAM_ENABLED='$WITH_WARP_UPSTREAM'
EOF
  chmod 0600 "$STATE_FILE"
}

write_singbox_service() {
  local singbox_binary dependencies
  singbox_binary="$(command -v sing-box)"
  dependencies=$(cat <<'EOF'
Wants=network-online.target
After=network-online.target
EOF
)
  if (( WITH_WARP_UPSTREAM )); then
    dependencies=$(cat <<'EOF'
Wants=network-online.target warp-svc.service
After=network-online.target warp-svc.service
Requires=warp-svc.service
EOF
)
  fi
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box VLESS HTTPUpgrade backend for Nginx
$dependencies

[Service]
Type=simple
ExecStart=$singbox_binary run -c $CONFIG_FILE
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

write_nginx_site() {
  local certificate_dir="/etc/letsencrypt/live/$DOMAIN"
  local mode="$1"
  local candidate previous_config had_enabled_link=0
  candidate="$(mktemp "/etc/nginx/sites-available/.${NGINX_SITE_NAME}.XXXXXX")"
  previous_config="$(mktemp "/etc/nginx/sites-available/.${NGINX_SITE_NAME}.previous.XXXXXX")"
  trap 'rm -f "$candidate" "$previous_config"' RETURN

  if [[ $mode == http ]]; then
    cat > "$candidate" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    if (\$cf_nginx_singbox_trusted_proxy = 0) { return 403; }

    root $WEB_ROOT/current;
    index index.html;
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF
  else
    [[ -r $certificate_dir/fullchain.pem && -r $certificate_dir/privkey.pem ]] \
      || die "Expected certificate files under $certificate_dir are missing."
    cat > "$candidate" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    if (\$cf_nginx_singbox_trusted_proxy = 0) { return 403; }

    root $WEB_ROOT/current;
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    ssl_certificate $certificate_dir/fullchain.pem;
    ssl_certificate_key $certificate_dir/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;

    if (\$cf_nginx_singbox_trusted_proxy = 0) { return 403; }

    root $WEB_ROOT/current;
    index index.html;

    location = $HTTPUPGRADE_PATH {
        proxy_pass http://127.0.0.1:$LOOPBACK_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$realip_remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "ok\\n";
    }

    location / { try_files \$uri \$uri/ /index.html; }
    location ~ /\\. { deny all; }
}
EOF
  fi
  chmod 0644 "$candidate"
  if [[ -e $NGINX_AVAILABLE ]]; then
    cp -a "$NGINX_AVAILABLE" "$previous_config"
  else
    rm -f "$previous_config"
  fi
  [[ -L $NGINX_ENABLED || -e $NGINX_ENABLED ]] && had_enabled_link=1
  install -m 0644 "$candidate" "$NGINX_AVAILABLE"
  ln -sfn "../sites-available/$(basename "$NGINX_AVAILABLE")" "$NGINX_ENABLED"
  if ! nginx -t; then
    if [[ -e $previous_config ]]; then
      install -m 0644 "$previous_config" "$NGINX_AVAILABLE"
    else
      rm -f "$NGINX_AVAILABLE"
    fi
    (( had_enabled_link )) || rm -f "$NGINX_ENABLED"
    die 'Candidate Nginx configuration is invalid. Review the Nginx error above; the service was not reloaded.'
  fi
  rm -f "$previous_config"
  trap - RETURN
  rm -f "$candidate"
}

request_certificate() {
  local certificate_dir="/etc/letsencrypt/live/$DOMAIN"
  if (( SKIP_CERTBOT )); then
    [[ -r $certificate_dir/fullchain.pem && -r $certificate_dir/privkey.pem ]] \
      || die '--skip-certbot was supplied but no existing certificate for this domain is available.'
    return
  fi
  if [[ -r $certificate_dir/fullchain.pem && -r $certificate_dir/privkey.pem ]] \
    && openssl x509 -checkend 2592000 -noout -in "$certificate_dir/fullchain.pem" >/dev/null; then
    info 'A valid certificate already exists; Certbot will keep managing its renewal.'
    return
  fi
  info "Requesting or renewing a Let's Encrypt certificate through the Cloudflare-proxied hostname"
  certbot certonly --webroot --webroot-path "$WEB_ROOT/current" -d "$DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring \
    || die "Certificate issuance failed. Confirm the orange cloud is enabled and Cloudflare can reach this VPS on TCP 80, then rerun the same command."
}

install_warp_upstream() {
  (( WITH_WARP_UPSTREAM )) || return 0
  local trace attempt listener
  check_warp_reserved_ports
  info 'Installing and registering official Cloudflare WARP in loopback-only SOCKS5 mode'
  apt-get install -y --no-install-recommends gpg lsb-release
  configure_warp_apt_repository
  apt-get update -y
  apt-get install -y cloudflare-warp
  systemctl enable --now warp-svc
  if ! warp-cli registration show >/dev/null 2>&1; then
    warp-cli --accept-tos registration new || die 'WARP registration failed before sing-box was routed through it.'
  fi
  warp-cli disconnect >/dev/null 2>&1 || true
  warp-cli tunnel protocol set MASQUE
  warp-cli proxy port "$WARP_PROXY_PORT"
  warp-cli mode proxy
  warp-cli connect
  for ((attempt = 1; attempt <= 20; attempt++)); do
    listener="$(listener_rows "$WARP_PROXY_PORT")"
    [[ $listener == *'127.0.0.1:'* && $listener == *'warp-svc'* ]] && break
    sleep 1
  done
  [[ ${listener:-} == *'127.0.0.1:'* && ${listener:-} == *'warp-svc'* ]] || die "WARP did not create its expected loopback SOCKS5 listener on 127.0.0.1:$WARP_PROXY_PORT."
  trace="$(curl -fsS --proxy "socks5h://127.0.0.1:$WARP_PROXY_PORT" --connect-timeout 8 --max-time 30 https://www.cloudflare.com/cdn-cgi/trace)" || die 'The WARP SOCKS5 connection test failed.'
  printf '%s\n' "$trace" | grep -Eq '^warp=(on|plus)$' || die 'WARP connected but Cloudflare did not report an active WARP tunnel.'
}

warp_is_configured() {
  [[ ${WARP_UPSTREAM_ENABLED:-0} == 1 ]]
}

verify_warp_upstream() {
  local trace
  warp_is_configured || return 0
  systemctl is-active --quiet warp-svc || die 'warp-svc is not active.'
  listener_rows "$WARP_PROXY_PORT" | grep -q 'warp-svc' \
    || die "warp-svc is not listening on its expected loopback SOCKS5 port $WARP_PROXY_PORT."
  listener_rows "$WARP_HEALTH_PORT" | grep -q 'sing-box' \
    || die "sing-box does not expose the loopback-only WARP health listener on $WARP_HEALTH_PORT."
  trace="$(curl -fsS --proxy "socks5h://127.0.0.1:$WARP_HEALTH_PORT" --connect-timeout 8 --max-time 20 https://www.cloudflare.com/cdn-cgi/trace)" \
    || die 'WARP health request through sing-box failed.'
  printf '%s\n' "$trace" | grep -Eq '^warp=(on|plus)$' \
    || die 'The sing-box WARP route did not report an active WARP tunnel.'
}

write_warp_health_monitor() {
  if (( ! WITH_WARP_UPSTREAM )); then
    systemctl disable --now cf-nginx-singbox-warp-health.timer >/dev/null 2>&1 || true
    rm -f "$WARP_HEALTH_SCRIPT" "$WARP_HEALTH_SERVICE" "$WARP_HEALTH_TIMER"
    systemctl daemon-reload
    return 0
  fi
  cat > "$WARP_HEALTH_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
trace="\$(curl -fsS --proxy 'socks5h://127.0.0.1:$WARP_HEALTH_PORT' --connect-timeout 8 --max-time 20 https://www.cloudflare.com/cdn-cgi/trace)"
printf '%s\\n' "\$trace" | grep -Eq '^warp=(on|plus)$'
EOF
  chmod 0700 "$WARP_HEALTH_SCRIPT"
  cat > "$WARP_HEALTH_SERVICE" <<EOF
[Unit]
Description=Check the $APP_NAME WARP upstream through sing-box
After=sing-box-cf-nginx.service warp-svc.service
Requires=sing-box-cf-nginx.service warp-svc.service

[Service]
Type=oneshot
ExecStart=$WARP_HEALTH_SCRIPT
EOF
  cat > "$WARP_HEALTH_TIMER" <<'EOF'
[Unit]
Description=Periodically check the cf-nginx-singbox WARP upstream

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
RandomizedDelaySec=90s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now cf-nginx-singbox-warp-health.timer
}

open_host_firewall_if_active() {
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    info "Allowing HTTP, HTTPS, and direct REALITY fallback TCP $BACKUP_PORT through active UFW"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow "$BACKUP_PORT/tcp"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    info "Allowing HTTP, HTTPS, and direct REALITY fallback TCP $BACKUP_PORT through active firewalld"
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-port="$BACKUP_PORT/tcp"
    firewall-cmd --reload
  else
    warn "No active host firewall was changed. Ensure the VPS provider firewall/security group allows TCP 80, 443, and $BACKUP_PORT."
  fi
}

enable_bbr() {
  cat > /etc/sysctl.d/99-cf-nginx-singbox-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null || warn 'Could not apply BBR; the proxy remains usable without it.'
  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    info 'BBR congestion control is available.'
  else
    warn 'This kernel does not expose BBR.'
  fi
}

configure_fail2ban() {
  if ! command -v fail2ban-client >/dev/null; then
    warn 'Fail2Ban is unavailable; the dedicated SSH brute-force jail was not configured.'
    return 0
  fi
  install -d -m 0755 /etc/fail2ban/jail.d
  # Keep this jail separate from sshd.local and any user-maintained policy. Proxy
  # handshake failures are deliberately not included: they are not reliable SSH
  # attacks and banning them would risk locking out legitimate proxy clients.
  cat > "$FAIL2BAN_JAIL_FILE" <<EOF
[$FAIL2BAN_JAIL_NAME]
enabled = true
filter = sshd
backend = systemd
port = ssh
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  if systemctl is-active --quiet fail2ban; then
    fail2ban-client reload || warn 'Fail2Ban is active but could not reload the dedicated SSH jail.'
  else
    systemctl enable --now fail2ban || warn 'Fail2Ban could not be started.'
  fi
  if fail2ban-client status "$FAIL2BAN_JAIL_NAME" >/dev/null 2>&1; then
    info 'Dedicated Fail2Ban SSH jail is active (5 failures / 10 minutes; ban 1 hour).'
  else
    warn 'Fail2Ban is running but the dedicated SSH jail is unavailable.'
  fi
}

verify_fail2ban() {
  if ! command -v fail2ban-client >/dev/null; then
    warn 'Fail2Ban is not installed; SSH brute-force protection is unavailable.'
    return 0
  fi
  if ! systemctl is-active --quiet fail2ban; then
    warn 'Fail2Ban is installed but not active.'
    return 0
  fi
  fail2ban-client status "$FAIL2BAN_JAIL_NAME" >/dev/null 2>&1 \
    || warn "Fail2Ban is active but the $FAIL2BAN_JAIL_NAME jail is not loaded."
}

disable_legacy_sync_if_migrating() {
  [[ -f /etc/github-nginx-site/settings ]] || return 0
  grep -Fqx "SITE_DOMAIN='$DOMAIN'" /etc/github-nginx-site/settings 2>/dev/null || return 0
  systemctl disable --now github-nginx-site-sync.timer >/dev/null 2>&1 || true
  warn 'Disabled the legacy github-nginx-site-sync timer for this domain so it cannot recreate a conflicting Nginx virtual host.'
}

backup_conflicting_domain_host() {
  local timestamp backup
  domain_already_claimed || return 0
  [[ -e $NGINX_AVAILABLE ]] && return 0
  (( FORCE )) || return 0
  timestamp="$(date +%Y%m%d%H%M%S)"
  backup="/etc/nginx/sites-available/${NGINX_SITE_NAME}.domain-conflict-$timestamp.conf"
  # The known legacy installer writes exactly this filename. Do not guess at or
  # delete arbitrary site files; a non-legacy conflicting vhost is left enabled
  # and nginx -t will make the conflict visible to the operator.
  if [[ -f /etc/nginx/sites-available/github-nginx-site.conf ]]; then
    cp -a /etc/nginx/sites-available/github-nginx-site.conf "$backup"
    rm -f /etc/nginx/sites-enabled/github-nginx-site.conf
    warn "Backed up and disabled the legacy GitHub site vhost: $backup"
  fi
}

write_client_profile_and_qr() {
  local primary_profile="$CLIENT_DIR/sing-box-vless-httpupgrade.json"
  local backup_profile="$CLIENT_DIR/sing-box-vless-reality-backup.json"
  local primary_uri backup_uri
  install -d -m 0700 "$CLIENT_DIR" "$QR_DIR"
  cat > "$primary_profile" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      {
        "tag": "google", "type": "tls", "server": "8.8.8.8", "server_port": 853,
        "tls": { "enabled": true, "server_name": "dns.google" }, "detour": "proxy"
      },
      {
        "tag": "local", "type": "https", "server": "223.5.5.5", "server_port": 443,
        "tls": { "enabled": true, "server_name": "dns.alidns.com" }
      }
    ],
    "rules": [
      { "rule_set": "geosite-geolocation-cn", "action": "route", "server": "local" }
    ],
    "final": "google"
  },
  "inbounds": [
    {
      "type": "tun", "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": true, "strict_route": true
    }
  ],
  "outbounds": [
    {
      "type": "vless", "tag": "proxy",
      "server": "$DOMAIN", "server_port": 443,
      "uuid": "$HTTPUPGRADE_UUID",
      "tls": {
        "enabled": true, "server_name": "$DOMAIN",
        "utls": { "enabled": true, "fingerprint": "chrome" }
      },
      "transport": {
        "type": "httpupgrade", "host": "$DOMAIN", "path": "$HTTPUPGRADE_PATH"
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "http_clients": [{ "tag": "proxy-download", "detour": "proxy" }],
  "route": {
    "default_domain_resolver": "local",
    "default_http_client": "proxy-download",
    "auto_detect_interface": true,
    "rules": [
      { "action": "sniff" },
      {
        "type": "logical", "mode": "or",
        "rules": [{ "protocol": "dns" }, { "port": 53 }],
        "action": "hijack-dns"
      },
      { "ip_is_private": true, "action": "route", "outbound": "direct" },
      { "rule_set": "geosite-geolocation-cn", "action": "route", "outbound": "direct" },
      {
        "type": "logical", "mode": "and",
        "rules": [
          { "rule_set": "geoip-cn" },
          { "rule_set": "geosite-geolocation-!cn", "invert": true }
        ],
        "action": "route", "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "type": "remote", "tag": "geosite-geolocation-cn", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs",
        "http_client": "proxy-download", "update_interval": "7d"
      },
      {
        "type": "remote", "tag": "geosite-geolocation-!cn", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs",
        "http_client": "proxy-download", "update_interval": "7d"
      },
      {
        "type": "remote", "tag": "geoip-cn", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "http_client": "proxy-download", "update_interval": "7d"
      }
    ],
    "final": "proxy"
  },
  "experimental": { "cache_file": { "enabled": true } }
}
EOF
  chmod 0600 "$primary_profile"
  sing-box check -c "$primary_profile" || die 'Generated Cloudflare HTTPUpgrade client profile is invalid.'

  cat > "$backup_profile" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      {
        "tag": "google", "type": "tls", "server": "8.8.8.8", "server_port": 853,
        "tls": { "enabled": true, "server_name": "dns.google" }, "detour": "proxy"
      },
      {
        "tag": "local", "type": "https", "server": "223.5.5.5", "server_port": 443,
        "tls": { "enabled": true, "server_name": "dns.alidns.com" }
      }
    ],
    "rules": [
      { "rule_set": "geosite-geolocation-cn", "action": "route", "server": "local" }
    ],
    "final": "google"
  },
  "inbounds": [
    {
      "type": "tun", "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": true, "strict_route": true
    }
  ],
  "outbounds": [
    {
      "type": "vless", "tag": "proxy",
      "server": "$VPS_IP", "server_port": $BACKUP_PORT,
      "uuid": "$BACKUP_UUID", "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true, "server_name": "$BACKUP_SNI",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true, "public_key": "$BACKUP_PUBLIC_KEY", "short_id": "$BACKUP_SHORT_ID"
        }
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "http_clients": [{ "tag": "proxy-download", "detour": "proxy" }],
  "route": {
    "default_domain_resolver": "local",
    "default_http_client": "proxy-download",
    "auto_detect_interface": true,
    "rules": [
      { "action": "sniff" },
      {
        "type": "logical", "mode": "or",
        "rules": [{ "protocol": "dns" }, { "port": 53 }],
        "action": "hijack-dns"
      },
      { "ip_is_private": true, "action": "route", "outbound": "direct" },
      { "rule_set": "geosite-geolocation-cn", "action": "route", "outbound": "direct" },
      {
        "type": "logical", "mode": "and",
        "rules": [
          { "rule_set": "geoip-cn" },
          { "rule_set": "geosite-geolocation-!cn", "invert": true }
        ],
        "action": "route", "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "type": "remote", "tag": "geosite-geolocation-cn", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs",
        "http_client": "proxy-download", "update_interval": "7d"
      },
      {
        "type": "remote", "tag": "geosite-geolocation-!cn", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs",
        "http_client": "proxy-download", "update_interval": "7d"
      },
      {
        "type": "remote", "tag": "geoip-cn", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "http_client": "proxy-download", "update_interval": "7d"
      }
    ],
    "final": "proxy"
  },
  "experimental": { "cache_file": { "enabled": true } }
}
EOF
  chmod 0600 "$backup_profile"
  sing-box check -c "$backup_profile" || die 'Generated direct REALITY fallback client profile is invalid.'

  primary_uri="vless://$HTTPUPGRADE_UUID@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&type=httpupgrade&host=$DOMAIN&path=$HTTPUPGRADE_PATH#$APP_NAME-CF-HTTPUpgrade"
  backup_uri="vless://$BACKUP_UUID@$VPS_IP:$BACKUP_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$BACKUP_SNI&fp=chrome&pbk=$BACKUP_PUBLIC_KEY&sid=$BACKUP_SHORT_ID&type=tcp&headerType=none#$APP_NAME-REALITY-backup"
  qrencode -l L -s 8 -o "$QR_DIR/vless-httpupgrade-shadowrocket.png" "$primary_uri"
  qrencode -l L -s 8 -o "$QR_DIR/vless-reality-backup-shadowrocket.png" "$backup_uri"
  printf '%s\n' "$primary_uri" > "$QR_DIR/vless-httpupgrade-shadowrocket.uri"
  printf '%s\n' "$backup_uri" > "$QR_DIR/vless-reality-backup-shadowrocket.uri"
  chmod 0600 "$QR_DIR"/vless-*.png "$QR_DIR"/vless-*.uri
}

show_client_artifacts() {
  local primary_uri_file="$QR_DIR/vless-httpupgrade-shadowrocket.uri"
  local backup_uri_file="$QR_DIR/vless-reality-backup-shadowrocket.uri"
  local primary_profile="$CLIENT_DIR/sing-box-vless-httpupgrade.json"
  local backup_profile="$CLIENT_DIR/sing-box-vless-reality-backup.json"

  [[ -r $STATE_FILE ]] || die "No $APP_NAME deployment was found at $STATE_FILE."
  DOMAIN="$(state_value DEPLOYED_DOMAIN)"
  VPS_IP="$(state_value VPS_IP)"
  valid_domain "$DOMAIN" || die 'Saved deployment domain is invalid.'
  valid_ipv4 "$VPS_IP" || die 'Saved VPS IPv4 is invalid.'
  [[ -s $primary_uri_file && -s $backup_uri_file && -s $primary_profile && -s $backup_profile ]] \
    || die 'Client QR or JSON artifacts are incomplete; run the installer with --force to rebuild them.'

  cat <<EOF

====================================================================
Client artifacts — keep these private
====================================================================
Client JSON download directory:
  $CLIENT_DIR

Download the two sing-box JSON profiles securely from your computer:
  scp root@$VPS_IP:$primary_profile .
  scp root@$VPS_IP:$backup_profile .

PNG QR files (for secure download or viewing):
  $QR_DIR/vless-httpupgrade-shadowrocket.png
  $QR_DIR/vless-reality-backup-shadowrocket.png

Terminal QR: Cloudflare primary — VLESS + TLS + HTTPUpgrade ($DOMAIN:443)
EOF
  qrencode -t ANSIUTF8 "$(tr -d '\n' < "$primary_uri_file")" \
    || warn 'Could not render the Cloudflare primary QR in this terminal; use its PNG file instead.'
  cat <<EOF

Terminal QR: direct backup — VLESS + REALITY + Vision ($VPS_IP:$BACKUP_PORT)
EOF
  qrencode -t ANSIUTF8 "$(tr -d '\n' < "$backup_uri_file")" \
    || warn 'Could not render the direct backup QR in this terminal; use its PNG file instead.'
  cat <<'EOF'

The QR codes contain connection credentials only. Import the JSON profiles into
sing-box when you need the built-in China-direct / other-traffic-proxy routing.
Do not paste URIs, QR screenshots, or JSON files into public chats or GitHub.
EOF
}

verify_deployment() {
  local code headers
  [[ -r $STATE_FILE ]] || die "Missing credentials: $STATE_FILE"
  [[ -s $CF_ACCESS_CONF ]] || die "Missing Cloudflare origin access configuration: $CF_ACCESS_CONF"
  [[ -s $NGINX_AVAILABLE ]] || die "Missing managed Nginx virtual host: $NGINX_AVAILABLE"
  grep -Fq "location = $HTTPUPGRADE_PATH" "$NGINX_AVAILABLE" \
    || die 'Nginx does not route the saved HTTPUpgrade path to sing-box.'
  grep -Fq '"type": "httpupgrade"' "$CONFIG_FILE" \
    || die 'sing-box is not configured with the HTTPUpgrade transport.'
  grep -Fq "\"path\": \"$HTTPUPGRADE_PATH\"" "$CONFIG_FILE" \
    || die 'Nginx and sing-box do not have the same saved HTTPUpgrade path.'
  grep -Fq '"tag": "vless-reality-direct-backup"' "$CONFIG_FILE" \
    || die 'The independent VLESS + REALITY backup inbound is missing.'
  grep -Fq "\"listen_port\": $BACKUP_PORT" "$CONFIG_FILE" \
    || die 'The direct backup is not configured for its expected TCP port.'
  [[ $(stat -c '%a' "$STATE_FILE") == 600 ]] || die "Credentials permissions must be 0600: $STATE_FILE"
  nginx -t >/dev/null || die 'Nginx configuration validation failed.'
  sing-box check -c "$CONFIG_FILE" >/dev/null || die 'Post-install sing-box validation failed.'
  sing-box check -c "$CLIENT_DIR/sing-box-vless-httpupgrade.json" >/dev/null \
    || die 'Generated sing-box client profile validation failed.'
  sing-box check -c "$CLIENT_DIR/sing-box-vless-reality-backup.json" >/dev/null \
    || die 'Generated direct REALITY fallback client profile validation failed.'
  [[ -s $QR_DIR/vless-httpupgrade-shadowrocket.png && -s $QR_DIR/vless-reality-backup-shadowrocket.png ]] \
    || die 'One or more VLESS QR-code images are missing.'
  systemctl is-active --quiet sing-box-cf-nginx || die 'sing-box-cf-nginx service is not active.'
  systemctl is-active --quiet nginx || die 'nginx service is not active.'
  systemctl is-active --quiet cf-nginx-singbox-cert-renew.timer \
    || die 'The certificate-renewal timer is not active.'
  if warp_is_configured; then
    systemctl is-active --quiet cf-nginx-singbox-warp-health.timer \
      || die 'The WARP health-monitor timer is not active.'
    verify_warp_upstream
  fi
  verify_fail2ban
  listener_rows "$LOOPBACK_PORT" | grep -q '127.0.0.1' || die "sing-box is not listening on 127.0.0.1:$LOOPBACK_PORT."
  listener_rows 443 | grep -q 'nginx' || die 'Nginx is not listening on TCP 443.'
  listener_rows "$BACKUP_PORT" | grep -q 'sing-box' \
    || die "sing-box is not listening on direct fallback TCP $BACKUP_PORT."
  code="$(curl -ksS --resolve "$DOMAIN:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$DOMAIN/healthz")"
  [[ $code == 200 ]] || die "Local HTTPS health endpoint returned HTTP $code instead of 200."
  headers="$(curl -sSI --connect-timeout 8 --max-time 20 "https://$DOMAIN/" || true)"
  if grep -qi '^server: cloudflare' <<< "$headers"; then
    info 'Public HTTPS response is currently traversing Cloudflare.'
  else
    warn 'Could not confirm a Cloudflare response header from this VPS yet. Confirm that the DNS record is orange-cloud proxied before using the node.'
  fi
  info "Validation passed: Nginx owns 443, the HTTPUpgrade backend is loopback-only, direct REALITY backup TCP $BACKUP_PORT is active, both QR profiles validate, and certificate renewal is scheduled."
}

health_check() {
  require_supported_host
  [[ -r $STATE_FILE ]] || die "No $APP_NAME deployment was found at $STATE_FILE."
  DOMAIN="$(state_value DEPLOYED_DOMAIN)"
  VPS_IP="$(state_value VPS_IP)"
  HTTPUPGRADE_UUID="$(state_value HTTPUPGRADE_UUID)"
  HTTPUPGRADE_PATH="$(state_value HTTPUPGRADE_PATH)"
  valid_domain "$DOMAIN" || die 'Saved deployment domain is invalid.'
  valid_ipv4 "$VPS_IP" || die 'Saved VPS IPv4 is invalid.'
  [[ -n $HTTPUPGRADE_UUID && -n $HTTPUPGRADE_PATH ]] || die 'Saved VLESS credentials are incomplete.'
  verify_deployment
}

preflight() {
  require_supported_host
  validate_inputs
  check_vps_address
  show_domain_resolution
  assert_existing_configuration_is_safe
  info 'Preflight passed. No files or services were changed.'
}

main() {
  if (( HEALTH_CHECK_ONLY )); then
    health_check
    return
  fi
  if (( SHOW_CLIENT_ARTIFACTS_ONLY )); then
    require_supported_host
    show_client_artifacts
    return
  fi
  require_supported_host
  restore_saved_warp_selection
  preflight
  (( PREFLIGHT_ONLY )) && return 0

  repair_existing_warp_apt_repository
  install_packages
  resolve_site_branch
  install_sing_box
  # Package installation can start Nginx, so run the listener and vhost checks
  # again with the actual Nginx binary available.
  assert_existing_configuration_is_safe
  write_cloudflare_origin_access
  write_site_settings
  write_site_sync_script
  write_site_units
  systemctl daemon-reload

  "$SYNC_SCRIPT"
  load_or_create_credentials
  install_warp_upstream
  write_singbox_config
  write_singbox_service
  backup_conflicting_domain_host
  write_nginx_site http
  systemctl enable --now nginx
  systemctl reload nginx
  open_host_firewall_if_active
  request_certificate
  write_nginx_site https
  systemctl reload nginx
  write_certificate_renewal
  systemctl daemon-reload
  systemctl enable --now sing-box-cf-nginx
  systemctl restart sing-box-cf-nginx
  systemctl enable --now cf-nginx-singbox-sync.timer
  systemctl enable --now cf-nginx-singbox-cert-renew.timer
  write_warp_health_monitor
  disable_legacy_sync_if_migrating
  enable_bbr
  configure_fail2ban
  write_client_profile_and_qr
  verify_deployment

  cat <<EOF

====================================================================
Installed: Cloudflare → Nginx → VLESS + HTTPUpgrade → sing-box
====================================================================
Domain:             $DOMAIN
Nginx HTTPS:        TCP 443 (Cloudflare-edge and localhost only)
sing-box backend:   127.0.0.1:$LOOPBACK_PORT
Direct backup:      VLESS + REALITY + Vision on $VPS_IP:$BACKUP_PORT (no Nginx/Cloudflare)
Website repository: $SITE_REPOSITORY_URL ($BRANCH), synchronized every 5 minutes
Certificate renewal: cf-nginx-singbox-cert-renew.timer (twice daily; reloads only after renewal)
SSH protection:      Fail2Ban jail $FAIL2BAN_JAIL_NAME (5 failures / 10 minutes; ban 1 hour)

Credentials:        $STATE_FILE
Cloudflare profile: $CLIENT_DIR/sing-box-vless-httpupgrade.json
Cloudflare URI:     $QR_DIR/vless-httpupgrade-shadowrocket.uri
Cloudflare QR:      $QR_DIR/vless-httpupgrade-shadowrocket.png
Backup profile:     $CLIENT_DIR/sing-box-vless-reality-backup.json
Backup URI:         $QR_DIR/vless-reality-backup-shadowrocket.uri
Backup QR:          $QR_DIR/vless-reality-backup-shadowrocket.png

Use a current client that supports VLESS + TLS + HTTPUpgrade for the Cloudflare
QR. The client connects to $DOMAIN:443; it must never use 127.0.0.1:$LOOPBACK_PORT.
The backup QR is VLESS + REALITY + Vision and connects directly to $VPS_IP:$BACKUP_PORT.

Operational checks:
  systemctl status sing-box-cf-nginx nginx
  sudo bash $0 --domain $DOMAIN --ip $VPS_IP --preflight
  sudo bash $0 --health-check
  systemctl status cf-nginx-singbox-cert-renew.timer
  sudo fail2ban-client status $FAIL2BAN_JAIL_NAME
  journalctl -u sing-box-cf-nginx -u cf-nginx-singbox-sync.service -n 100 --no-pager
EOF
  if warp_is_configured; then
    cat <<EOF

WARP upstream:      enabled through warp-cli SOCKS5 on 127.0.0.1:$WARP_PROXY_PORT
WARP monitor:       cf-nginx-singbox-warp-health.timer (every 10 minutes)
WARP check:         systemctl status cf-nginx-singbox-warp-health.timer
EOF
  else
    cat <<'EOF'

WARP upstream:      disabled (proxy traffic uses the VPS direct egress)
EOF
  fi
  show_client_artifacts
}

main
