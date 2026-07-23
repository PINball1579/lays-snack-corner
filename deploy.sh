#!/usr/bin/env bash
#
# Deploy site/ to the Cloudways application root.
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

rsync -avz --delete \
  --exclude '.DS_Store' \
  --exclude 'link.txt' \
  "$REPO_ROOT/site/" \
  "$LAYS_REMOTE_HOST:$LAYS_REMOTE_PATH/"

printf 'deployed site/ -> %s:%s/\n' "$LAYS_REMOTE_HOST" "$LAYS_REMOTE_PATH"
