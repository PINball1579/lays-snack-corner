#!/usr/bin/env bash
#
# Post-deploy checklist. Runs every check against a given base URL and
# reports pass/fail per check, exiting non-zero if any fail.
#
#   ./verify-deploy.sh https://laysmortorlor.com     # through Cloudflare
#   ./verify-deploy.sh https://203.0.113.10          # raw origin, bypassing Cloudflare
#
# Works against the raw origin IP as well as the public domain: when the
# host in BASE_URL is a bare IP literal, TLS certificate verification is
# relaxed (the Cloudflare Origin Certificate is issued for the domain name
# and signed by Cloudflare's own CA, not a publicly trusted one -- neither
# matches when connecting straight to an IP) and domain-hostname-dependent
# checks (the www redirect) are pinned to that IP with curl --resolve
# instead of relying on public DNS. The cf-cache-status check only makes
# sense when Cloudflare is actually in front of the request, so it is
# skipped in that mode.
#
# Reads the expected /go redirect target from the local site/link.txt
# (override with LAYS_LINK_FILE), the same file set-link.sh writes.

set -uo pipefail

DOMAIN="laysmortorlor.com"
WWW_DOMAIN="www.laysmortorlor.com"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINK_FILE="${LAYS_LINK_FILE:-$REPO_ROOT/site/link.txt}"

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

[ $# -eq 1 ] || die "usage: ./verify-deploy.sh <base-url>  (e.g. https://laysmortorlor.com or https://<origin-ip>)"

RAW_BASE="${1%/}"
[ -n "$RAW_BASE" ] || die "base URL is empty"

[ -f "$LINK_FILE" ] || die "cannot read expected /go destination: $LINK_FILE does not exist (set LAYS_LINK_FILE to override)"
EXPECTED_LINK="$(cat "$LINK_FILE")"
[ -n "$EXPECTED_LINK" ] || die "$LINK_FILE is empty; cannot determine the expected /go destination"

# --- Parse host out of the base URL, decide IP-vs-domain mode --------------

HOST="$(printf '%s' "$RAW_BASE" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*##')"
[ -n "$HOST" ] || die "could not parse a host out of '$RAW_BASE'"

IS_IP=0
if printf '%s' "$HOST" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  IS_IP=1
elif printf '%s' "$HOST" | grep -q ':'; then
  IS_IP=1
fi

HTTPS_BASE="https://${HOST}"
HTTP_BASE="http://${HOST}"

# curl flags shared by every HTTPS request in this script.
# Every array below is expanded as ${arr[@]+"${arr[@]}"}, never "${arr[@]}":
# under `set -u`, bash 3.2 -- which macOS still ships and which this script
# is run from -- treats an EMPTY array expansion as an unbound variable and
# aborts. The naive form made every check in this script fail.
CURL_TLS_FLAGS=()
if [ "$IS_IP" -eq 1 ]; then
  # Bypassing Cloudflare entirely: the origin cert cannot match a bare IP,
  # and it is signed by Cloudflare's own CA, which curl does not trust by
  # default. Both are expected in this mode, not a real failure.
  CURL_TLS_FLAGS=(-k)
fi

# --- Reporting -----------------------------------------------------------

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { printf '[PASS] %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf '[FAIL] %s -- %s\n' "$1" "$2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { printf '[SKIP] %s -- %s\n' "$1" "$2"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

# --- Checks ----------------------------------------------------------------

check_root_200() {
  local name="GET / returns 200 and serves the page"
  local out
  out="$(curl -sS ${CURL_TLS_FLAGS[@]+"${CURL_TLS_FLAGS[@]}"} -o /dev/null -w '%{http_code}' "$HTTPS_BASE/")"
  if [ "$out" = "200" ]; then
    pass "$name"
  else
    fail "$name" "got HTTP $out"
  fi
}

check_go_302() {
  local name="GET /go returns 302 (never 301) to the current link.txt destination"
  local out status location
  out="$(curl -sS ${CURL_TLS_FLAGS[@]+"${CURL_TLS_FLAGS[@]}"} -o /dev/null -w '%{http_code} %{redirect_url}' "$HTTPS_BASE/go")"
  status="${out%% *}"
  location="${out#* }"
  if [ "$status" = "302" ] && [ "$location" = "$EXPECTED_LINK" ]; then
    pass "$name"
  else
    fail "$name" "got status '$status', location '$location' (expected 302, '$EXPECTED_LINK')"
  fi
}

check_go_slash_302() {
  local name="GET /go/ (trailing slash) also returns 302"
  local out status location
  out="$(curl -sS ${CURL_TLS_FLAGS[@]+"${CURL_TLS_FLAGS[@]}"} -o /dev/null -w '%{http_code} %{redirect_url}' "$HTTPS_BASE/go/")"
  status="${out%% *}"
  location="${out#* }"
  if [ "$status" = "302" ] && [ "$location" = "$EXPECTED_LINK" ]; then
    pass "$name"
  else
    fail "$name" "got status '$status', location '$location' (expected 302, '$EXPECTED_LINK')"
  fi
}

check_linktxt_403() {
  local name="GET /link.txt returns 403"
  local out
  out="$(curl -sS ${CURL_TLS_FLAGS[@]+"${CURL_TLS_FLAGS[@]}"} -o /dev/null -w '%{http_code}' "$HTTPS_BASE/link.txt")"
  if [ "$out" = "403" ]; then
    pass "$name"
  else
    fail "$name" "got HTTP $out"
  fi
}

check_asset_cache_immutable() {
  local name="GET /assets/bg.png carries Cache-Control: public, max-age=31536000, immutable"
  local headers
  headers="$(curl -sSI ${CURL_TLS_FLAGS[@]+"${CURL_TLS_FLAGS[@]}"} "$HTTPS_BASE/assets/bg.png" | tr -d '\r')"
  if printf '%s\n' "$headers" | grep -qi '^Cache-Control: public, max-age=31536000, immutable$'; then
    pass "$name"
  else
    fail "$name" "Cache-Control header missing or wrong; headers were:\n$headers"
  fi
}

check_root_cache_nocache() {
  local name="GET / carries Cache-Control: no-cache"
  local headers
  headers="$(curl -sSI ${CURL_TLS_FLAGS[@]+"${CURL_TLS_FLAGS[@]}"} "$HTTPS_BASE/" | tr -d '\r')"
  if printf '%s\n' "$headers" | grep -qi '^Cache-Control: no-cache$'; then
    pass "$name"
  else
    fail "$name" "Cache-Control header missing or wrong; headers were:\n$headers"
  fi
}

check_go_cache_nostore() {
  local name="GET /go carries Cache-Control: no-store"
  local headers
  headers="$(curl -sSI ${CURL_TLS_FLAGS[@]+"${CURL_TLS_FLAGS[@]}"} "$HTTPS_BASE/go" | tr -d '\r')"
  if printf '%s\n' "$headers" | grep -qi '^Cache-Control:.*no-store'; then
    pass "$name"
  else
    fail "$name" "Cache-Control: no-store not found; headers were:\n$headers"
  fi
}

check_go_cf_cache_bypass() {
  local name="GET /go is never served from the Cloudflare cache"
  if [ "$IS_IP" -eq 1 ]; then
    skip "$name" "running against the raw origin IP; Cloudflare is not in front of this request"
    return
  fi
  local headers
  headers="$(curl -sSI ${CURL_TLS_FLAGS[@]+"${CURL_TLS_FLAGS[@]}"} "$HTTPS_BASE/go" | tr -d '\r')"
  # BYPASS and DYNAMIC both mean "not served from cache". Cloudflare reports
  # DYNAMIC for responses it considers inherently uncacheable -- a 302 with
  # no-store qualifies -- regardless of an explicit bypass rule, so asserting
  # BYPASS specifically fails on a correctly configured zone. What actually
  # matters is that it is never HIT: a cached redirect would keep serving
  # yesterday's destination after set-link.sh reported success.
  if printf '%s\n' "$headers" | grep -qiE '^cf-cache-status: *(BYPASS|DYNAMIC)$'; then
    pass "$name"
  else
    fail "$name" "expected cf-cache-status BYPASS or DYNAMIC (never HIT); headers were:\n$headers"
  fi
}

check_http_upgrades_to_https() {
  local name="http:// upgrades to https://"
  local out status location
  out="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$HTTP_BASE/")"
  status="${out%% *}"
  location="${out#* }"
  case "$status" in
    301|302) ;;
    *) fail "$name" "got status '$status' (expected a redirect)"; return ;;
  esac
  case "$location" in
    https://*) pass "$name" ;;
    *) fail "$name" "redirected to '$location', which is not https://" ;;
  esac
}

check_www_redirects_to_apex() {
  local name="www.$DOMAIN redirects to the apex"
  local resolve_args=()
  if [ "$IS_IP" -eq 1 ]; then
    resolve_args=(--resolve "${WWW_DOMAIN}:443:${HOST}")
  fi
  local out status location
  out="$(curl -sS ${CURL_TLS_FLAGS[@]+"${CURL_TLS_FLAGS[@]}"} ${resolve_args[@]+"${resolve_args[@]}"} -o /dev/null -w '%{http_code} %{redirect_url}' "https://${WWW_DOMAIN}/")"
  status="${out%% *}"
  location="${out#* }"
  case "$status" in
    301|302) ;;
    *) fail "$name" "got status '$status' (expected a redirect)"; return ;;
  esac
  case "$location" in
    "https://${DOMAIN}"*) pass "$name" ;;
    *) fail "$name" "redirected to '$location', expected https://${DOMAIN}/..." ;;
  esac
}

check_no_directory_listing() {
  local name="no directory listing at /assets/"
  local status body
  status="$(curl -sS ${CURL_TLS_FLAGS[@]+"${CURL_TLS_FLAGS[@]}"} -o /dev/null -w '%{http_code}' "$HTTPS_BASE/assets/")"
  if [ "$status" = "200" ]; then
    body="$(curl -sS ${CURL_TLS_FLAGS[@]+"${CURL_TLS_FLAGS[@]}"} "$HTTPS_BASE/assets/")"
    if printf '%s' "$body" | grep -qi 'Index of /assets'; then
      fail "$name" "server returned a directory listing (200 with 'Index of /assets')"
      return
    fi
  fi
  pass "$name"
}

# --- Run everything ----------------------------------------------------

printf 'verifying %s (host: %s, mode: %s)\n\n' "$HTTPS_BASE" "$HOST" "$([ "$IS_IP" -eq 1 ] && echo 'raw origin IP' || echo 'public domain')"

check_root_200
check_go_302
check_go_slash_302
check_linktxt_403
check_asset_cache_immutable
check_root_cache_nocache
check_go_cache_nostore
check_go_cf_cache_bypass
check_http_upgrades_to_https
check_www_redirects_to_apex
check_no_directory_listing

printf '\n%d passed, %d failed, %d skipped\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

[ "$FAIL_COUNT" -eq 0 ]
