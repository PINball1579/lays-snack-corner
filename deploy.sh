#!/usr/bin/env bash
#
# Deploy site/ to the Droplet's Apache document root
# (/var/www/laysmortorlor.com, provisioned by provision.sh).
#
#   ./deploy.sh
#
# Reads LAYS_REMOTE_HOST and LAYS_REMOTE_PATH from .env.deploy.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$REPO_ROOT/.env.deploy" ]; then
  # shellcheck disable=SC1091
  . "$REPO_ROOT/.env.deploy"
fi

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ -n "${LAYS_REMOTE_HOST:-}" ] || die "LAYS_REMOTE_HOST is not set (see .env.deploy.example)"
[ -n "${LAYS_REMOTE_PATH:-}" ] || die "LAYS_REMOTE_PATH is not set (see .env.deploy.example)"

# --exclude 'link.txt' is load-bearing, not incidental: link.txt is operator
# state owned by set-link.sh (today's CTA destination), not build output.
# Without this exclusion, a plain --delete sync would overwrite it with the
# committed seed value on every deploy and silently revert the live CTA.
#
# --chmod=D755,F644 forces sane modes on the server regardless of whatever
# permissions the files happen to carry on the deploying machine -- www-data
# needs read access to every file and read+execute on every directory to
# serve them at all.
rsync -avz --delete \
  --exclude '.DS_Store' \
  --exclude 'link.txt' \
  --chmod=D755,F644 \
  "$REPO_ROOT/site/" \
  "$LAYS_REMOTE_HOST:$LAYS_REMOTE_PATH/"

printf 'deployed site/ -> %s:%s/\n' "$LAYS_REMOTE_HOST" "$LAYS_REMOTE_PATH"

# link.txt is excluded from the sync above (by design, see comment), so its
# mode is never touched by --chmod either. It still needs to be verified
# sane here: a 600 link.txt (e.g. left over from a manual `cat >` on the
# server, see set-link.sh's own comment on this exact failure mode) is
# unreadable by www-data and produces a silently dead CTA -- go.php falls
# back to FALLBACK_URL with no error in any log. Skip quietly if link.txt
# does not exist yet (e.g. a brand-new box before set-link.sh has ever run).
if ! ssh "$LAYS_REMOTE_HOST" \
  "test -e '$LAYS_REMOTE_PATH/link.txt' && chmod 644 '$LAYS_REMOTE_PATH/link.txt' || true"; then
  die "could not verify/fix the mode of $LAYS_REMOTE_PATH/link.txt on $LAYS_REMOTE_HOST (SSH command failed) -- the site was synced, but link.txt's permissions were not confirmed sane"
fi

printf 'verified: link.txt mode is sane on %s\n' "$LAYS_REMOTE_HOST"
