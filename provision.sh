#!/usr/bin/env bash
#
# One-time (but safely re-runnable) provisioning for the Lay's campaign
# Droplet: Apache 2.4 + PHP-FPM on Ubuntu 24.04, origin locked to
# Cloudflare, TLS via a Cloudflare Origin Certificate.
#
#   sudo ./provision.sh
#
# Must be run as root on a fresh Ubuntu 24.04 Droplet. Safe to re-run: every
# step either checks current state first or overwrites its own
# previously-written output, so running this twice converges on the same
# result instead of accumulating duplicate config or firewall rules.
#
# Before running, place the Cloudflare Origin Certificate on the box:
#   /root/cloudflare-origin.pem   (certificate)
#   /root/cloudflare-origin.key   (private key)
# Generate them in the Cloudflare dashboard under
# SSL/TLS -> Origin Server -> Create Certificate.

set -euo pipefail

DOMAIN="laysmortorlor.com"
WWW_DOMAIN="www.laysmortorlor.com"
DOCROOT="/var/www/${DOMAIN}"

VHOST_FILE="/etc/apache2/sites-available/${DOMAIN}.conf"
REMOTEIP_CONF="/etc/apache2/conf-available/lays-remoteip.conf"

CF_IPV4_URL="https://www.cloudflare.com/ips-v4"
CF_IPV6_URL="https://www.cloudflare.com/ips-v6"
# Where the CIDR ranges applied by the PREVIOUS run of this script are
# recorded, so a re-run can delete exactly those ufw rules before adding the
# current ones instead of either accumulating duplicates or doing a blanket
# `ufw reset` (which would also drop the SSH rule).
CF_RANGES_STATE_FILE="/etc/lays-cloudflare-ranges.conf"

ORIGIN_CERT_SRC="/root/cloudflare-origin.pem"
ORIGIN_KEY_SRC="/root/cloudflare-origin.key"
ORIGIN_CERT_DST="/etc/ssl/certs/cloudflare-origin.pem"
ORIGIN_KEY_DST="/etc/ssl/private/cloudflare-origin.key"

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$1"
}

# --- Preflight ---------------------------------------------------------

require_root_and_ubuntu_24_04() {
  [ "$(id -u)" -eq 0 ] || die "must be run as root (try: sudo ./provision.sh)"

  [ -r /etc/os-release ] || die "cannot read /etc/os-release; unable to confirm this is Ubuntu 24.04"
  # shellcheck disable=SC1091
  . /etc/os-release

  [ "${ID:-}" = "ubuntu" ] || die "this script only supports Ubuntu 24.04 LTS (detected ID=${ID:-unknown})"
  [ "${VERSION_ID:-}" = "24.04" ] || die "this script only supports Ubuntu 24.04 LTS (detected VERSION_ID=${VERSION_ID:-unknown})"
}

# --- Packages & modules --------------------------------------------------

install_packages() {
  info "apt-get update"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq

  info "installing apache2, php8.3-fpm, ufw, curl, unattended-upgrades"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    apache2 php8.3-fpm ufw curl unattended-upgrades
}

enable_apache_modules() {
  info "enabling apache modules"
  a2enmod rewrite headers ssl proxy_fcgi setenvif remoteip >/dev/null
  a2enconf php8.3-fpm >/dev/null
}

# --- Document root --------------------------------------------------------

setup_docroot() {
  info "creating document root $DOCROOT"
  mkdir -p "$DOCROOT"
  chown -R www-data:www-data "$DOCROOT"
  chmod 755 "$DOCROOT"
}

# --- Cloudflare origin certificate -----------------------------------------

install_origin_certificate() {
  if [ ! -s "$ORIGIN_CERT_SRC" ]; then
    die "Cloudflare Origin Certificate not found at $ORIGIN_CERT_SRC (or it is empty). Generate one in the Cloudflare dashboard under SSL/TLS -> Origin Server -> Create Certificate, and place the certificate at $ORIGIN_CERT_SRC before re-running."
  fi
  if [ ! -s "$ORIGIN_KEY_SRC" ]; then
    die "Cloudflare Origin Certificate private key not found at $ORIGIN_KEY_SRC (or it is empty). Generate one in the Cloudflare dashboard under SSL/TLS -> Origin Server -> Create Certificate, and place the private key at $ORIGIN_KEY_SRC before re-running."
  fi

  info "installing Cloudflare Origin Certificate to $ORIGIN_CERT_DST / $ORIGIN_KEY_DST"
  install -o root -g root -m 644 "$ORIGIN_CERT_SRC" "$ORIGIN_CERT_DST"
  install -o root -g root -m 600 "$ORIGIN_KEY_SRC" "$ORIGIN_KEY_DST"
  chmod 600 "$ORIGIN_KEY_DST"
}

# --- Apache vhosts ----------------------------------------------------------

write_vhost() {
  info "writing $VHOST_FILE"
  cat > "$VHOST_FILE" <<EOF
# Managed by provision.sh. Apex ($DOMAIN) is canonical; www redirects to it.

<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias ${WWW_DOMAIN}

    <IfModule mod_rewrite.c>
        RewriteEngine On
        RewriteRule ^ https://${DOMAIN}%{REQUEST_URI} [L,R=301]
    </IfModule>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-access.log combined
</VirtualHost>

<VirtualHost *:443>
    ServerName ${DOMAIN}
    ServerAlias ${WWW_DOMAIN}
    DocumentRoot ${DOCROOT}

    SSLEngine on
    SSLCertificateFile ${ORIGIN_CERT_DST}
    SSLCertificateKeyFile ${ORIGIN_KEY_DST}
    SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1

    # www is not canonical here -- apex is. Redirect before serving content.
    <IfModule mod_rewrite.c>
        RewriteEngine On
        RewriteCond %{HTTP_HOST} ^${WWW_DOMAIN}\$ [NC]
        RewriteRule ^ https://${DOMAIN}%{REQUEST_URI} [L,R=301]
    </IfModule>

    <Directory ${DOCROOT}>
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch \.php\$>
        SetHandler "proxy:unix:/run/php/php8.3-fpm.sock|fcgi://localhost"
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-ssl-access.log combined
</VirtualHost>
EOF
}

disable_default_site() {
  info "disabling default vhost"
  if [ -e /etc/apache2/sites-enabled/000-default.conf ]; then
    a2dissite 000-default >/dev/null
  fi
  if [ -e /etc/apache2/sites-enabled/default-ssl.conf ]; then
    a2dissite default-ssl >/dev/null
  fi
}

enable_site() {
  info "enabling ${DOMAIN}.conf"
  a2ensite "${DOMAIN}.conf" >/dev/null
}

# --- mod_remoteip: log real visitor IPs from CF-Connecting-IP ---------------
#
# Origin is locked to Cloudflare (see configure_firewall), so every request
# Apache sees on 80/443 arrives via a Cloudflare edge IP. Without remoteip,
# every access-log line and every %{REMOTE_ADDR} would show that Cloudflare
# IP instead of the real visitor.

configure_remoteip() {
  local ranges_file="$1"
  info "writing $REMOTEIP_CONF"
  [ -s "$ranges_file" ] || die "internal error: no Cloudflare ranges available for mod_remoteip config"
  {
    printf '# Managed by provision.sh. Trust CF-Connecting-IP only from Cloudflare edges.\n'
    printf 'RemoteIPHeader CF-Connecting-IP\n'
    while IFS= read -r cidr; do
      [ -n "$cidr" ] || continue
      printf 'RemoteIPTrustedProxy %s\n' "$cidr"
    done < "$ranges_file"
  } > "$REMOTEIP_CONF"
  a2enconf lays-remoteip >/dev/null
}

# --- Firewall ----------------------------------------------------------
#
# THIS IS THE SECTION THAT CAN BRICK THE DROPLET. The SSH allow rule MUST
# be added before `ufw enable` -- enabling ufw with a default-deny incoming
# policy and no SSH rule locks out the operator permanently, recoverable
# only through DigitalOcean's web console. Do not reorder the calls below.

looks_like_cidr_list() {
  # $1: file to check, $2: "4" or "6"
  local file="$1" family="$2"
  [ -s "$file" ] || return 1

  local pattern
  if [ "$family" = "4" ]; then
    pattern='^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'
  else
    pattern='^[0-9A-Fa-f:]+/[0-9]{1,3}$'
  fi

  # Every non-blank line must match, and there must be at least one line.
  local total non_blank matching
  total="$(wc -l < "$file" | tr -d ' ')"
  non_blank="$(grep -c . "$file" || true)"
  matching="$(grep -cE "$pattern" "$file" || true)"

  [ "$total" -gt 0 ] || return 1
  [ "$non_blank" -gt 0 ] || return 1
  [ "$non_blank" = "$matching" ]
}

fetch_cloudflare_ranges() {
  # $1: destination file to write the combined v4+v6 CIDR list to
  local dest="$1"
  local tmp_v4 tmp_v6
  tmp_v4="$(mktemp)"
  tmp_v6="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_v4' '$tmp_v6'" RETURN

  info "fetching Cloudflare IPv4 ranges from $CF_IPV4_URL"
  if ! curl -fsS --max-time 15 "$CF_IPV4_URL" -o "$tmp_v4"; then
    die "failed to fetch Cloudflare IPv4 ranges from $CF_IPV4_URL. Aborting -- refusing to open 80/443 to the world or proceed with a partial ruleset."
  fi
  if ! looks_like_cidr_list "$tmp_v4" 4; then
    die "response from $CF_IPV4_URL does not look like a list of IPv4 CIDR ranges. Aborting -- refusing to open 80/443 to the world or proceed with a partial ruleset."
  fi

  info "fetching Cloudflare IPv6 ranges from $CF_IPV6_URL"
  if ! curl -fsS --max-time 15 "$CF_IPV6_URL" -o "$tmp_v6"; then
    die "failed to fetch Cloudflare IPv6 ranges from $CF_IPV6_URL. Aborting -- refusing to open 80/443 to the world or proceed with a partial ruleset."
  fi
  if ! looks_like_cidr_list "$tmp_v6" 6; then
    die "response from $CF_IPV6_URL does not look like a list of IPv6 CIDR ranges. Aborting -- refusing to open 80/443 to the world or proceed with a partial ruleset."
  fi

  cat "$tmp_v4" "$tmp_v6" > "$dest"
}

configure_firewall() {
  # $1: file already containing the fetched+validated Cloudflare CIDR list
  # (fetched once in main() and shared with configure_remoteip, so this
  # script only hits Cloudflare's IP-list endpoints once per run).
  local new_ranges="$1"

  info "setting default-deny-incoming / allow-outgoing policy"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null

  # --- SSH rule, added before ufw is ever enabled. Do not move this below
  # the `ufw enable` step further down in this function. ---
  info "allowing SSH (OpenSSH) before enabling ufw"
  # The "OpenSSH" ufw application profile ships with the openssh-server
  # package present on every standard Ubuntu cloud image, so this succeeds
  # in the normal case. Fall back to the raw port so a missing/renamed
  # profile can never be the reason SSH access is left unprotected -- this
  # is the one place in this script where a silent failure bricks the box.
  if ! ufw allow OpenSSH >/dev/null 2>&1; then
    ufw allow 22/tcp >/dev/null
  fi

  # Replace any Cloudflare rules from a previous run of this script,
  # rather than accumulating duplicates on re-run.
  if [ -s "$CF_RANGES_STATE_FILE" ]; then
    info "removing Cloudflare firewall rules from a previous run"
    while IFS= read -r cidr; do
      [ -n "$cidr" ] || continue
      ufw delete allow from "$cidr" to any port 80 proto tcp >/dev/null 2>&1 || true
      ufw delete allow from "$cidr" to any port 443 proto tcp >/dev/null 2>&1 || true
    done < "$CF_RANGES_STATE_FILE"
  fi

  info "allowing 80/443 from current Cloudflare ranges only"
  while IFS= read -r cidr; do
    [ -n "$cidr" ] || continue
    ufw allow from "$cidr" to any port 80 proto tcp comment 'cloudflare' >/dev/null
    ufw allow from "$cidr" to any port 443 proto tcp comment 'cloudflare' >/dev/null
  done < "$new_ranges"

  install -o root -g root -m 644 "$new_ranges" "$CF_RANGES_STATE_FILE"

  info "enabling ufw"
  ufw --force enable >/dev/null
}

# --- Unattended upgrades -------------------------------------------------

enable_unattended_upgrades() {
  info "enabling unattended-upgrades"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
}

# --- Config test & reload -------------------------------------------------

test_and_reload_apache() {
  info "running apache2ctl configtest"
  if ! apache2ctl configtest; then
    die "apache2ctl configtest failed -- refusing to reload Apache with a broken config. Fix the error above and re-run."
  fi

  info "restarting apache2 and php8.3-fpm"
  systemctl enable --now php8.3-fpm >/dev/null
  systemctl restart php8.3-fpm
  systemctl enable --now apache2 >/dev/null
  systemctl restart apache2
}

main() {
  require_root_and_ubuntu_24_04
  install_packages
  enable_apache_modules
  setup_docroot
  install_origin_certificate
  write_vhost
  disable_default_site
  enable_site

  local cf_ranges
  cf_ranges="$(mktemp)"
  # Fetch and validate ONCE, before touching ufw at all. If this fails,
  # `die` exits (via set -e) with ufw completely untouched -- see
  # fetch_cloudflare_ranges for the abort-don't-fall-back rule.
  fetch_cloudflare_ranges "$cf_ranges"
  configure_remoteip "$cf_ranges"
  configure_firewall "$cf_ranges"
  rm -f "$cf_ranges"

  enable_unattended_upgrades
  test_and_reload_apache

  info "provisioning complete: https://${DOMAIN}"
}

main "$@"
