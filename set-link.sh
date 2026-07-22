#!/usr/bin/env bash
#
# Set the CTA destination for the Lay's Snack Corner landing page.
#
#   ./set-link.sh https://promo.example.com/today
#
# Writes the local link file, records the change, pushes to the live server
# over SSH, then verifies that /go actually points at the new URL.
#
# Environment overrides:
#   LAYS_LINK_FILE     local link file        (default: site/link.txt)
#   LAYS_HISTORY_FILE  change log             (default: link-history.log)
#   LAYS_SKIP_REMOTE   set to 1 to skip SSH push and verification
#   LAYS_REMOTE_HOST   ssh target, e.g. master_abc@203.0.113.10
#   LAYS_REMOTE_PATH   remote public_html path
#   LAYS_SITE_URL      public origin, e.g. https://example.com

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LINK_FILE="${LAYS_LINK_FILE:-$REPO_ROOT/site/link.txt}"
HISTORY_FILE="${LAYS_HISTORY_FILE:-$REPO_ROOT/link-history.log}"
REMOTE_HOST="${LAYS_REMOTE_HOST:-}"
REMOTE_PATH="${LAYS_REMOTE_PATH:-}"
SITE_URL="${LAYS_SITE_URL:-}"

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

url="${1-}"

if [ $# -eq 0 ]; then
  die "no URL given. usage: ./set-link.sh https://promo.example.com/today"
fi

[ -n "$url" ] || die "URL is empty. usage: ./set-link.sh https://promo.example.com/today"

case "$url" in
  *$'\n'*) die "URL must be a single line" ;;
esac

# Must match go.php's MAX_URL_LENGTH (site/go.php) exactly: no client can
# follow an unbounded Location header, and a URL this script accepts but
# go.php then rejects is a dead CTA with no error anywhere.
if [ "${#url}" -gt 2048 ]; then
  die "URL exceeds the 2048-character maximum enforced by go.php (length: ${#url})"
fi

# --- Accept-set policy ------------------------------------------------
# This regex is INTENTIONALLY stricter than go.php's is_valid_https_url()
# (site/go.php) in every place the two differ: it also rejects uppercase
# HTTPS://, IPv6 literals ([::1]), trailing-dot FQDNs, bare IP hosts, and
# https://localhost/ that go.php would accept. That direction is safe --
# worst case it blocks the operator, who edits the URL and retries; it
# never lets an invalid URL slip past validation into link.txt.
#
# Everywhere else, the two validators MUST agree, or a URL this script
# accepts can be one go.php then rejects -- a dead CTA with no error
# anywhere, since visitors would silently get the fallback URL. That is
# why the hostname character class below excludes `_`: PHP's
# FILTER_VALIDATE_URL (which go.php uses) rejects underscores in a
# hostname, so this script must too.
#
# When touching this regex: it must NEVER become MORE permissive than
# go.php's is_valid_https_url(). Loosening it is exactly how a URL this
# script accepts ends up rejected downstream -- or worse, exploited by
# something go.php was relying on this script to have already blocked.
# When in doubt, keep rejecting.
#
# Require https, a dotted host, and no whitespace. Rejects http://, bare
# schemes, javascript:, and hosts with no TLD.
if ! [[ "$url" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}(:[0-9]+)?(/[^[:space:]]*)?$ ]]; then
  die "must be a well-formed https:// URL with a dotted hostname (got: $url)"
fi

printf '%s\n' "$url" > "$LINK_FILE"
printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$url" >> "$HISTORY_FILE"
printf 'local   : %s\n' "$LINK_FILE"

if [ "${LAYS_SKIP_REMOTE:-0}" = "1" ]; then
  printf 'remote  : skipped (LAYS_SKIP_REMOTE=1)\n'
  exit 0
fi

[ -n "$REMOTE_HOST" ] || die "LAYS_REMOTE_HOST is not set"
[ -n "$REMOTE_PATH" ] || die "LAYS_REMOTE_PATH is not set"

if ! printf '%s\n' "$url" | ssh "$REMOTE_HOST" "cat > '$REMOTE_PATH/link.txt'"; then
  die "SSH push to $REMOTE_HOST failed. The local link file and history log were already updated to '$url', but the remote server was NOT updated -- the live site is still serving the previous URL. Re-run this command to retry the push."
fi
printf 'remote  : %s:%s/link.txt\n' "$REMOTE_HOST" "$REMOTE_PATH"

if [ -z "$SITE_URL" ]; then
  printf 'verify  : skipped (LAYS_SITE_URL is not set)\n'
  exit 0
fi

live="$(curl -sS -o /dev/null -w '%{redirect_url}' "$SITE_URL/go")"
[ "$live" = "$url" ] || die "verification failed: $SITE_URL/go points at '$live', expected '$url'"
printf 'verified: %s/go -> %s\n' "$SITE_URL" "$url"
