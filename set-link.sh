#!/usr/bin/env bash
#
# Set the CTA destination for the Lay's Snack Corner landing page.
#
#   ./set-link.sh https://promo.example.com/today
#
# Writes the local link file, pushes to the live server over SSH, records the
# change in the history log once the push has actually succeeded, then
# verifies that /go actually points at the new URL.
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
# A trailing slash in LAYS_SITE_URL would build "$SITE_URL/go" as "//go",
# which 404s and turns a healthy deploy into a confusing verification
# failure.
SITE_URL="${SITE_URL%/}"

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
# This regex (plus the ASCII check just below it) must never be MORE
# permissive than go.php's is_valid_https_url() (site/go.php): a URL this
# script accepts but go.php then rejects is a dead CTA with no error
# anywhere, since visitors would silently get the fallback URL.
#
# It is INTENTIONALLY stricter than go.php in a few places. Rejecting these
# only blocks the operator, who edits the URL and retries; it never lets an
# invalid URL slip past validation into link.txt:
#   - uppercase HTTPS://
#   - IPv6 literals ([::1])
#   - trailing-dot FQDNs (example.com.)
#   - bare IP hosts (203.0.113.10)
#   - https://localhost/ (no dot)
#   - underscores in the hostname -- PHP's FILTER_VALIDATE_URL (which go.php
#     uses) also rejects underscores in a hostname, so this is agreement,
#     not extra strictness, but the hostname character class below depends
#     on it, hence calling it out
#
# Everywhere else the two validators MUST agree exactly. A whole-branch
# review (2026-07-23) found three more places they did not, all now fixed:
#   - ASCII only. FILTER_VALIDATE_URL rejects any non-ASCII byte, but the
#     path/query class below (`[^[:space:]]`) matches any non-whitespace
#     byte, including multi-byte UTF-8 -- and a Thai slug or Thai query
#     value is entirely plausible on this campaign. The explicit grep right
#     after the regex closes that gap; it must stay, and it must run AFTER
#     the regex (this comment, and the check itself, describe the ordering).
#   - Port range. FILTER_VALIDATE_URL rejects any port above 65535 (the
#     16-bit ceiling); the port group below is bounded to 1-65535 to match,
#     instead of the previous unbounded `[0-9]+`.
#   - Punycode/IDN TLDs (`xn--...`) are explicitly ALLOWED, which is a
#     LOOSENING relative to the previous regex, not a restriction --
#     FILTER_VALIDATE_URL accepts them, and a `.ไทย`-style TLD is plausible
#     for this campaign. Rejecting them would only have blocked the
#     operator for no safety benefit, which is the wrong kind of strict.
#
# When touching this regex or the ASCII/port checks: re-run the validator
# differential against go.php's is_valid_https_url() (a `php -r` harness that
# includes the real function body) before committing. This script must NEVER
# become MORE permissive than go.php in any way not explicitly listed above.
# Loosening it beyond go.php is exactly how a URL this script accepts ends up
# rejected downstream -- or worse, exploited by something go.php was relying
# on this script to have already blocked. When in doubt, keep rejecting.
#
# Require https, a dotted host (or a punycode/IDN TLD), a 1-65535 port if
# given, and no whitespace. Rejects http://, bare schemes, javascript:, and
# hosts with no TLD.
if ! [[ "$url" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.([A-Za-z]{2,}|xn--[A-Za-z0-9]+)(:([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?(/[^[:space:]]*)?$ ]]; then
  die "must be a well-formed https:// URL with a dotted hostname and a port in 1-65535, if any (got: $url)"
fi

# go.php's FILTER_VALIDATE_URL rejects any non-ASCII character. The regex
# above cannot express that (its path/query class matches any non-whitespace
# byte, multi-byte UTF-8 included), so check separately. See the comment
# block above for why this matters on a Thai campaign.
printf '%s' "$url" | LC_ALL=C grep -qE '^[!-~]+$' \
  || die "URL must be printable ASCII only -- go.php's FILTER_VALIDATE_URL rejects non-ASCII characters. Percent-encode them first (got: $url)"

printf '%s\n' "$url" > "$LINK_FILE"
printf 'local   : %s\n' "$LINK_FILE"
# site/link.txt is tracked in git specifically so a full `rsync --delete`
# redeploy never reverts the live link to a stale committed value (see
# deploy.sh's --exclude 'link.txt'). That protection only holds if this
# change actually gets committed.
printf 'reminder: %s has changed -- commit it, or a future redeploy will revert the live link\n' "$LINK_FILE" >&2

if [ "${LAYS_SKIP_REMOTE:-0}" = "1" ]; then
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$url" >> "$HISTORY_FILE"
  printf 'remote  : skipped (LAYS_SKIP_REMOTE=1)\n'
  exit 0
fi

[ -n "$REMOTE_HOST" ] || die "LAYS_REMOTE_HOST is not set"
[ -n "$REMOTE_PATH" ] || die "LAYS_REMOTE_PATH is not set"

# Write to a temp file, fix its mode, then atomically rename into place:
#   - `cat > link.txt` directly truncates then streams, so a dropped
#     connection can leave a PARTIAL, still-syntactically-valid URL live
#     (e.g. ".../day-1" truncated to ".../day" is itself a valid https URL
#     that go.php would happily accept and 302 every visitor into a 404).
#     `mv -f` within the same directory is atomic, so visitors either see
#     the old complete URL or the new complete URL, never a partial one.
#   - `chmod 644` before the move guarantees the mode is correct regardless
#     of the remote umask. If link.txt does not already exist server-side
#     and the umask is restrictive, a plain `cat >` can land it at 600 --
#     unreadable by the web server, and go.php silently falls back for
#     every visitor with no error anywhere.
if ! printf '%s\n' "$url" | ssh "$REMOTE_HOST" "cat > '$REMOTE_PATH/link.txt.tmp' && chmod 644 '$REMOTE_PATH/link.txt.tmp' && mv -f '$REMOTE_PATH/link.txt.tmp' '$REMOTE_PATH/link.txt'"; then
  die "SSH push to $REMOTE_HOST failed. The local link file was already updated to '$url', but the remote server was NOT updated -- the live site is still serving the previous URL. The history log was not recorded, since the push did not succeed. Re-run this command to retry the push."
fi
printf 'remote  : %s:%s/link.txt\n' "$REMOTE_HOST" "$REMOTE_PATH"
# Only recorded once the push has actually succeeded -- appending before the
# push (the previous behavior) left the log asserting a URL that may never
# have gone live if the push then failed.
printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$url" >> "$HISTORY_FILE"

if [ -z "$SITE_URL" ]; then
  # To stderr, not stdout: this is a warning that the operator's success
  # signal (exit 0) does NOT mean the CTA was confirmed working, not routine
  # progress output.
  printf 'warning : verification skipped (LAYS_SITE_URL is not set) -- the push above was not confirmed live\n' >&2
  exit 0
fi

live="$(curl -sS -o /dev/null -w '%{redirect_url}' "$SITE_URL/go")"
[ "$live" = "$url" ] || die "verification failed: $SITE_URL/go points at '$live', expected '$url'"
printf 'verified: %s/go -> %s\n' "$SITE_URL" "$url"
