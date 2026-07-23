# Lay's มตล Snack Corner Landing Page — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy a single-page, mobile-first Lay's campaign landing site whose one call-to-action redirects through a stable `/go` endpoint, so the daily-changing destination URL is updated by a single CLI command with no rebuild and no redeploy.

**Architecture:** Static `index.html` + `style.css` render three images over a full-bleed background using flexbox, sized from ratios measured off the 1080×1920 design. The CTA links to `/go`, which Apache rewrites to `go.php` — ~30 lines of PHP that read the destination from a server-side `link.txt` and issue a `302`. `set-link.sh` validates a URL, writes it locally and remotely over SSH, and verifies the live redirect. No build step, no bundler, no JavaScript in the page.

**Tech Stack:** HTML5, CSS3 (flexbox, `clamp()`, `svh`, `env(safe-area-inset-*)`), PHP 8.3-FPM (one file), Bash, Apache 2.4 `.htaccess`. Tests: `bats` 1.13 (unit) and `@playwright/test` 1.61 (smoke + visual). Hosting: a bare DigitalOcean Droplet (Ubuntu 24.04), provisioned by `provision.sh` — originally planned as Cloudways, changed 2026-07-23 (see Task 5/6 below and the design spec §9.0). Edge: Cloudflare with an Origin Certificate, origin locked to Cloudflare's IP ranges.

## Global Constraints

Every task's requirements implicitly include this section.

- **Design source of truth:** `design.png`, 1080×1920. All three assets are exported at exactly their composition size within it, so ratios are exact, not approximate.
- **Brand colors** (sampled directly from `material/bg.png`, do not guess): pink `#FFA5E8`, yellow `#FFD400`, blue `#24ABFF`, green `#04933B`, star cream `#FFF0A9`.
- **Page background color** must be `#FFA5E8` — the pink at the top of the artwork — so a slow `bg.png` never flashes white.
- **Mobile is the primary target.** Every layout decision is validated at 390×844 first.
- **Viewport height uses `svh`/`dvh`, never bare `vh`.** On iOS Safari `vh` resolves against the expanded viewport and pushes the CTA under the browser chrome.
- **The redirect status is `302`, never `301`.** A permanent redirect on a daily-changing destination gets cached indefinitely by browsers.
- **`go.php` reads its destination only from the server-side `link.txt`.** It must never accept a URL from a query parameter, path segment, header, or cookie. That is an open redirect and a phishing vector aimed at the Lay's brand.
- **`set-link.sh` accepts `https://` only.** It rejects `http://`, malformed URLs, empty input, and multi-line input.
- **Source assets in `material/` are never modified.** Assets are copied into `site/assets/` under web-safe names.
- **No JavaScript in the delivered page.** The CTA is a plain `<a>`.
- **RESOLVED (2026-07-23):** the site domain is the apex `laysmortorlor.com` (with `www` redirecting to it), and `go.php`'s `FALLBACK_URL` is `https://www.instagram.com/laysthailand`. Both were deferred at planning time; neither is a placeholder any longer. No placeholder is permitted anywhere in shipped code.

---

### Task 1: Tooling, asset pipeline, and local dev server

Establishes the repo's test harness and gets the four artwork files into place under web-safe names. The rename is the point: `material/add your.png` contains a space, which is invalid in a URL without escaping.

**Files:**
- Create: `package.json`
- Create: `tests/assets.bats`
- Create: `tests/router.php`
- Create: `site/assets/bg.png`, `site/assets/logo-lays.png`, `site/assets/logo-mtr.png`, `site/assets/btn-add-template.png`, `site/assets/og-image.png`
- Create: `site/favicon.png`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing (first task)
- Produces:
  - `site/assets/` populated with the five asset filenames above
  - `tests/router.php` — a `php -S` router that maps `/go` and `/go/` to `site/go.php` and serves everything else statically, mirroring the production Apache rewrite
  - npm scripts `test:unit` (runs `bats tests/*.bats`), `test:e2e` (runs `playwright test`), `test` (both), `serve` (starts PHP on `127.0.0.1:8888`)

- [ ] **Step 1: Install PHP**

macOS 15+ ships no PHP. It is needed to run and test `go.php` locally.

```bash
brew install php
php --version
```

Expected: `PHP 8.x.x (cli)` or newer.

- [ ] **Step 2: Create `package.json`**

```json
{
  "name": "lays-snack-corner",
  "version": "1.0.0",
  "private": true,
  "description": "Lay's มตล Snack Corner campaign landing page",
  "scripts": {
    "serve": "php -S 127.0.0.1:8888 -t site tests/router.php",
    "test:unit": "bats tests/*.bats",
    "test:e2e": "playwright test",
    "test": "npm run test:unit && npm run test:e2e"
  },
  "devDependencies": {
    "@playwright/test": "^1.61.1",
    "bats": "^1.13.0"
  }
}
```

- [ ] **Step 3: Install dependencies**

```bash
npm install
npx playwright install chromium
```

Expected: `node_modules/` created, Chromium downloaded.

- [ ] **Step 4: Write the failing asset test**

Create `tests/assets.bats`:

```bash
#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "background asset exists at 1080x1920" {
  run file "$REPO/site/assets/bg.png"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PNG image data, 1080 x 1920"* ]]
}

@test "Lay's logo asset exists at 190x179" {
  run file "$REPO/site/assets/logo-lays.png"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PNG image data, 190 x 179"* ]]
}

@test "mtr badge asset exists at 472x274" {
  run file "$REPO/site/assets/logo-mtr.png"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PNG image data, 472 x 274"* ]]
}

@test "CTA button asset exists at 913x280" {
  run file "$REPO/site/assets/btn-add-template.png"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PNG image data, 913 x 280"* ]]
}

@test "Open Graph image exists at 1080x1920" {
  run file "$REPO/site/assets/og-image.png"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PNG image data, 1080 x 1920"* ]]
}

@test "favicon exists" {
  [ -f "$REPO/site/favicon.png" ]
}

@test "no deployed asset filename contains a space" {
  run bash -c "find '$REPO/site' -name '* *' -print"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 5: Run the test to verify it fails**

```bash
npm run test:unit
```

Expected: FAIL — every test reports the file does not exist.

- [ ] **Step 6: Copy and rename the assets**

```bash
mkdir -p site/assets
cp "material/bg.png"        site/assets/bg.png
cp "material/logo.png"      site/assets/logo-lays.png
cp "material/mtr.png"       site/assets/logo-mtr.png
cp "material/add your.png"  site/assets/btn-add-template.png
cp "design.png"             site/assets/og-image.png
cp "material/logo.png"      site/favicon.png
```

- [ ] **Step 7: Run the test to verify it passes**

```bash
npm run test:unit
```

Expected: PASS — 7 tests, 0 failures.

- [ ] **Step 8: Create the local dev router**

Create `tests/router.php`. Production Apache rewrites `/go` to `go.php`; PHP's built-in server has no `.htaccess`, so this one file keeps local behavior identical to production for that route.

```php
<?php
// Router for PHP's built-in dev server. Mirrors the production Apache rule
// `RewriteRule ^go/?$ go.php [L]` so local and deployed behavior match.
// Usage: php -S 127.0.0.1:8888 -t site tests/router.php

declare(strict_types=1);

$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

if (preg_match('#^/go/?$#', (string) $path) === 1) {
    require __DIR__ . '/../site/go.php';
    return true;
}

// Fall through to the static file server.
return false;
```

- [ ] **Step 9: Update `.gitignore`**

Replace the contents of `.gitignore` with:

```
.DS_Store
node_modules/
link-history.log
test-results/
playwright-report/
blob-report/
.playwright/
```

`site/link.txt` is deliberately **not** ignored — it must be tracked so a full redeploy of `site/` never reverts the live link to a stale value.

- [ ] **Step 10: Commit**

```bash
git add package.json package-lock.json .gitignore tests/assets.bats tests/router.php site/
git commit -m "chore: add test harness and web-safe campaign assets"
```

---

### Task 2: `go.php` redirect endpoint

The one piece of server-side logic. It has exactly one input — a file we control — and one job.

**Files:**
- Create: `site/go.php`
- Create: `site/link.txt`
- Test: `tests/go.bats`

**Interfaces:**
- Consumes: `tests/router.php` from Task 1
- Produces:
  - `site/go.php` — responds `302` with a `Location` header and `Cache-Control: no-store`
  - `site/link.txt` — a single-line file holding the current destination URL; written by `set-link.sh` in Task 3
  - PHP functions `is_valid_https_url(string $url): bool` and `resolve_destination(string $path, string $fallback): string`
  - Constant `FALLBACK_URL` — set to `'/'`, replaced with a real URL in Task 6

- [ ] **Step 1: Write the failing tests**

Create `tests/go.bats`:

```bash
#!/usr/bin/env bats

BASE="http://127.0.0.1:8899"

setup_file() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO
  php -S 127.0.0.1:8899 -t "$REPO/site" "$REPO/tests/router.php" >/dev/null 2>&1 &
  echo $! > "$BATS_FILE_TMPDIR/server.pid"
  for _ in $(seq 1 60); do
    curl -sS -o /dev/null "http://127.0.0.1:8899/go" && break
    sleep 0.1
  done
}

teardown_file() {
  kill "$(cat "$BATS_FILE_TMPDIR/server.pid")" 2>/dev/null || true
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LINK="$REPO/site/link.txt"
  if [ -f "$LINK" ]; then cp "$LINK" "$BATS_TEST_TMPDIR/link.bak"; fi
}

teardown() {
  if [ -f "$BATS_TEST_TMPDIR/link.bak" ]; then
    cp "$BATS_TEST_TMPDIR/link.bak" "$LINK"
  else
    rm -f "$LINK"
  fi
}

# Prints "<status> <resolved redirect target>"
probe() {
  curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE/go"
}

@test "valid link.txt redirects to that URL" {
  printf 'https://valid.example.com/today\n' > "$LINK"
  run probe
  [ "$output" = "302 https://valid.example.com/today" ]
}

@test "status is 302 and never 301" {
  printf 'https://valid.example.com/today\n' > "$LINK"
  run curl -sS -o /dev/null -w '%{http_code}' "$BASE/go"
  [ "$output" = "302" ]
}

@test "missing link.txt falls back instead of erroring" {
  rm -f "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "empty link.txt falls back" {
  printf '' > "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "whitespace-only link.txt falls back" {
  printf '   \n\n' > "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "malformed link.txt falls back" {
  printf 'not a url at all\n' > "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "non-TLS http:// destination is refused and falls back" {
  printf 'http://insecure.example.com/\n' > "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "javascript: scheme is refused and falls back" {
  printf 'javascript:alert(1)\n' > "$LINK"
  run probe
  [ "$output" = "302 $BASE/" ]
}

@test "query string cannot override the destination (open redirect guard)" {
  printf 'https://valid.example.com/today\n' > "$LINK"
  run curl -sS -o /dev/null -w '%{redirect_url}' "$BASE/go?url=https://evil.example.com/"
  [ "$output" = "https://valid.example.com/today" ]
}

@test "response is not cacheable" {
  printf 'https://valid.example.com/today\n' > "$LINK"
  run bash -c "curl -sS -D - -o /dev/null '$BASE/go' | tr -d '\r'"
  [[ "$output" == *"Cache-Control: no-store"* ]]
}

@test "trailing slash form /go/ also redirects" {
  printf 'https://valid.example.com/today\n' > "$LINK"
  run curl -sS -o /dev/null -w '%{http_code}' "$BASE/go/"
  [ "$output" = "302" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
npx bats tests/go.bats
```

Expected: FAIL — `site/go.php` does not exist, so the `require` in the router raises a fatal error and every probe returns `500`.

- [ ] **Step 3: Write `go.php`**

Create `site/go.php`:

```php
<?php
/**
 * CTA redirect endpoint.
 *
 * The destination is read ONLY from the server-side link.txt. It must never be
 * taken from a query parameter, path segment, header, or cookie: a redirect
 * whose target comes from user input is an open redirect, and on a page
 * carrying Lay's branding that is a phishing vector aimed at the brand.
 */

declare(strict_types=1);

const LINK_FILE = __DIR__ . '/link.txt';

// Used when link.txt is missing, empty, or invalid. '/' sends the visitor to
// this site's own root rather than an error page. Task 6 replaces this with a
// permanent campaign URL if one is provided.
const FALLBACK_URL = '/';

function is_valid_https_url(string $url): bool
{
    if ($url === '' || strpbrk($url, "\r\n") !== false) {
        return false;
    }
    if (filter_var($url, FILTER_VALIDATE_URL) === false) {
        return false;
    }

    return strtolower((string) parse_url($url, PHP_URL_SCHEME)) === 'https';
}

function resolve_destination(string $path, string $fallback): string
{
    if (!is_file($path) || !is_readable($path)) {
        return $fallback;
    }

    $raw = file_get_contents($path);
    if ($raw === false) {
        return $fallback;
    }

    $url = trim($raw);

    return is_valid_https_url($url) ? $url : $fallback;
}

$destination = resolve_destination(LINK_FILE, FALLBACK_URL);

header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
header('Pragma: no-cache');
header('Referrer-Policy: strict-origin-when-cross-origin');

// 302 (temporary), never 301. The destination changes daily; a permanent
// redirect would be cached indefinitely by browsers with no way to clear it.
header('Location: ' . $destination, true, 302);
exit;
```

- [ ] **Step 4: Create the initial `link.txt`**

```bash
printf 'https://www.lays.co.th/\n' > site/link.txt
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
npx bats tests/go.bats
```

Expected: PASS — 11 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add site/go.php site/link.txt tests/go.bats
git commit -m "feat: add /go redirect endpoint with fallback and open-redirect guard"
```

---

### Task 3: `set-link.sh` daily update command

The daily operator interface. Validation happens before the write so a typo is rejected at the keyboard rather than discovered by customers.

**Files:**
- Create: `set-link.sh`
- Test: `tests/set-link.bats`

**Interfaces:**
- Consumes: `site/link.txt` from Task 2
- Produces: `./set-link.sh <https-url>` — validates, writes `site/link.txt`, appends to `link-history.log`, pushes to the server over SSH, then verifies the live redirect
- Environment overrides used by tests and by deployment:
  - `LAYS_LINK_FILE` — path to the local link file (default `site/link.txt`)
  - `LAYS_HISTORY_FILE` — path to the history log (default `link-history.log`)
  - `LAYS_SKIP_REMOTE=1` — write locally only, skip SSH and verification
  - `LAYS_REMOTE_HOST`, `LAYS_REMOTE_PATH`, `LAYS_SITE_URL` — deployment target, filled in during Task 5

- [ ] **Step 1: Write the failing tests**

Create `tests/set-link.bats`:

```bash
#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO/set-link.sh"
  export LAYS_LINK_FILE="$BATS_TEST_TMPDIR/link.txt"
  export LAYS_HISTORY_FILE="$BATS_TEST_TMPDIR/history.log"
  export LAYS_SKIP_REMOTE=1
}

@test "script is executable" {
  [ -x "$SCRIPT" ]
}

@test "accepts a valid https URL and writes it" {
  run "$SCRIPT" "https://promo.example.com/day-1"
  [ "$status" -eq 0 ]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/day-1" ]
}

@test "writes exactly one line with no trailing whitespace" {
  "$SCRIPT" "https://promo.example.com/day-1"
  run wc -l < "$LAYS_LINK_FILE"
  [ "$(echo "$output" | tr -d ' ')" = "1" ]
}

@test "appends a timestamped entry to the history log" {
  "$SCRIPT" "https://promo.example.com/day-1"
  "$SCRIPT" "https://promo.example.com/day-2"
  run wc -l < "$LAYS_HISTORY_FILE"
  [ "$(echo "$output" | tr -d ' ')" = "2" ]
  run grep -c "https://promo.example.com/day-2" "$LAYS_HISTORY_FILE"
  [ "$output" = "1" ]
}

@test "overwrites rather than appends to the link file" {
  "$SCRIPT" "https://promo.example.com/day-1"
  "$SCRIPT" "https://promo.example.com/day-2"
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/day-2" ]
}

@test "rejects http:// and leaves the existing link untouched" {
  "$SCRIPT" "https://promo.example.com/good"
  run "$SCRIPT" "http://promo.example.com/bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"https://"* ]]
  [ "$(cat "$LAYS_LINK_FILE")" = "https://promo.example.com/good" ]
}

@test "rejects a malformed URL" {
  run "$SCRIPT" "not a url"
  [ "$status" -ne 0 ]
}

@test "rejects a scheme-only URL" {
  run "$SCRIPT" "https://"
  [ "$status" -ne 0 ]
}

@test "rejects a host with no dot" {
  run "$SCRIPT" "https://localhost/promo"
  [ "$status" -ne 0 ]
}

@test "rejects empty input" {
  run "$SCRIPT" ""
  [ "$status" -ne 0 ]
}

@test "rejects a missing argument" {
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}

@test "rejects multi-line input" {
  run "$SCRIPT" "$(printf 'https://a.example.com/\nhttps://b.example.com/')"
  [ "$status" -ne 0 ]
}

@test "rejects a javascript: scheme" {
  run "$SCRIPT" "javascript:alert(1)"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
npx bats tests/set-link.bats
```

Expected: FAIL — `set-link.sh` does not exist.

- [ ] **Step 3: Write `set-link.sh`**

Create `set-link.sh`:

```bash
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

# Require https, a dotted host, and no whitespace. Rejects http://, bare
# schemes, javascript:, and hosts with no TLD.
if ! [[ "$url" =~ ^https://[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?\.[A-Za-z]{2,}(:[0-9]+)?(/[^[:space:]]*)?$ ]]; then
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

printf '%s\n' "$url" | ssh "$REMOTE_HOST" "cat > '$REMOTE_PATH/link.txt'"
printf 'remote  : %s:%s/link.txt\n' "$REMOTE_HOST" "$REMOTE_PATH"

if [ -z "$SITE_URL" ]; then
  printf 'verify  : skipped (LAYS_SITE_URL is not set)\n'
  exit 0
fi

live="$(curl -sS -o /dev/null -w '%{redirect_url}' "$SITE_URL/go")"
[ "$live" = "$url" ] || die "verification failed: $SITE_URL/go points at '$live', expected '$url'"
printf 'verified: %s/go -> %s\n' "$SITE_URL" "$url"
```

- [ ] **Step 4: Make it executable**

```bash
chmod +x set-link.sh
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
npx bats tests/set-link.bats
```

Expected: PASS — 13 tests, 0 failures.

- [ ] **Step 6: Run the full unit suite**

```bash
npm run test:unit
```

Expected: PASS — 31 tests total across `assets.bats`, `go.bats`, `set-link.bats`.

- [ ] **Step 7: Commit**

```bash
git add set-link.sh tests/set-link.bats
git commit -m "feat: add set-link.sh for validated daily CTA URL updates"
```

---

### Task 4: The page — `index.html` and `style.css`

Three images over a full-bleed background. The ratios below are derived from the design and are not to be adjusted by eye.

**Files:**
- Create: `site/index.html`
- Create: `site/style.css`
- Create: `playwright.config.ts`
- Test: `tests/e2e/smoke.spec.ts`
- Test: `tests/e2e/visual.spec.ts`

**Interfaces:**
- Consumes: `site/assets/*` from Task 1, the `/go` route from Task 2, `tests/router.php` from Task 1
- Produces: `site/index.html` containing `a.cta[href="/go"]`, `img.logo`, `img.badge`, and `div.bg > img`; CSS custom properties `--col`, `--pad-top`, `--gap-logo`, `--gap-badge`

**Ratio derivation** (all three assets are 1:1 within the 1080×1920 design, so these are exact):

| Element | Source size | Width as share of `--col` | Derivation |
|---|---|---|---|
| Lay's logo | 190×179 | 20.8% | 190 / 913 |
| มตล badge | 472×274 | 51.7% | 472 / 913 |
| CTA button | 913×280 | 100% | 913 / 913 |

| Vertical gap | Design px | Share of height | CSS |
|---|---|---|---|
| top → logo | 95 | 4.9% | `clamp(20px, 4.9svh, 72px)` |
| logo → badge | 186 | 9.7% | `clamp(28px, 9.7svh, 140px)` |
| badge → CTA | 111 | 5.8% | `clamp(18px, 5.8svh, 84px)` |
| CTA → bottom | 795 | 41.4% | implicit remainder |

- [ ] **Step 1: Write the failing smoke test**

Create `tests/e2e/smoke.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

const MOBILE = { width: 390, height: 844 };

test('page loads with no console errors', async ({ page }) => {
  const errors: string[] = [];
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(m.text());
  });
  page.on('pageerror', (e) => errors.push(e.message));

  const response = await page.goto('/');

  expect(response?.status()).toBe(200);
  expect(errors).toEqual([]);
});

test('all four images load successfully', async ({ page }) => {
  await page.goto('/');

  const sources = [
    'assets/bg.png',
    'assets/logo-lays.png',
    'assets/logo-mtr.png',
    'assets/btn-add-template.png',
  ];

  for (const src of sources) {
    const naturalWidth = await page
      .locator(`img[src="${src}"]`)
      .evaluate((el) => (el as HTMLImageElement).naturalWidth);
    expect(naturalWidth, `${src} failed to load`).toBeGreaterThan(0);
  }
});

test('CTA points at /go and is reachable without scrolling on mobile', async ({ page }) => {
  await page.setViewportSize(MOBILE);
  await page.goto('/');

  const cta = page.locator('a.cta');
  await expect(cta).toHaveAttribute('href', '/go');
  await expect(cta).toBeInViewport();
});

test('CTA tap target meets the 44px minimum', async ({ page }) => {
  await page.setViewportSize(MOBILE);
  await page.goto('/');

  const box = await page.locator('a.cta').boundingBox();
  expect(box).not.toBeNull();
  expect(box!.height).toBeGreaterThanOrEqual(44);
});

test('CTA follows through to the current link.txt destination', async ({ page }) => {
  await page.goto('/');

  const response = await page.request.get('/go', { maxRedirects: 0 });
  expect(response.status()).toBe(302);
  expect(response.headers()['location']).toMatch(/^https:\/\//);
});

test('page never scrolls horizontally', async ({ page }) => {
  for (const size of [MOBILE, { width: 320, height: 568 }, { width: 1440, height: 900 }]) {
    await page.setViewportSize(size);
    await page.goto('/');

    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow, `horizontal overflow at ${size.width}px`).toBeLessThanOrEqual(0);
  }
});

test('images declare intrinsic dimensions to prevent layout shift', async ({ page }) => {
  await page.goto('/');

  const missing = await page.evaluate(() =>
    Array.from(document.querySelectorAll('img'))
      .filter((img) => !img.getAttribute('width') || !img.getAttribute('height'))
      .map((img) => img.getAttribute('src')),
  );
  expect(missing).toEqual([]);
});
```

- [ ] **Step 2: Write the Playwright config**

Create `playwright.config.ts`:

```typescript
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: 'list',
  use: {
    baseURL: 'http://127.0.0.1:8888',
    trace: 'on-first-retry',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: 'php -S 127.0.0.1:8888 -t site tests/router.php',
    url: 'http://127.0.0.1:8888/index.html',
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
  },
});
```

- [ ] **Step 3: Run the smoke test to verify it fails**

```bash
npx playwright test tests/e2e/smoke.spec.ts
```

Expected: FAIL — the web server never becomes ready because `site/index.html` does not exist.

- [ ] **Step 4: Write `index.html`**

Create `site/index.html`. The literal `REPLACE-WITH-DOMAIN.example.com` appears only in the two absolute Open Graph URLs and is substituted in Task 6.

```html
<!doctype html>
<html lang="th">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="theme-color" content="#FFA5E8">

  <title>มตล Snack Corner | Lay's</title>
  <meta name="description" content="มตล ใหม่ ต้องลอง — Snack Corner จาก Lay's เพิ่มเทมเพลตของคุณได้เลย">

  <meta property="og:type" content="website">
  <meta property="og:title" content="มตล Snack Corner | Lay's">
  <meta property="og:description" content="มตล ใหม่ ต้องลอง — Snack Corner จาก Lay's เพิ่มเทมเพลตของคุณได้เลย">
  <meta property="og:image" content="https://REPLACE-WITH-DOMAIN.example.com/assets/og-image.png">
  <meta property="og:url" content="https://REPLACE-WITH-DOMAIN.example.com/">
  <meta name="twitter:card" content="summary_large_image">

  <link rel="icon" href="favicon.png" type="image/png">
  <link rel="preload" as="image" href="assets/bg.png">
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <div class="bg" aria-hidden="true">
    <img src="assets/bg.png" alt="" width="1080" height="1920" fetchpriority="high">
  </div>

  <main class="stage">
    <img class="logo" src="assets/logo-lays.png" alt="Lay's" width="190" height="179">

    <img class="badge" src="assets/logo-mtr.png" alt="มตล ใหม่ ต้องลอง — Snack Corner"
         width="472" height="274">

    <a class="cta" href="/go" aria-label="Add your template">
      <img src="assets/btn-add-template.png" alt="" width="913" height="280">
    </a>
  </main>
</body>
</html>
```

- [ ] **Step 5: Write `style.css`**

Create `site/style.css`:

```css
/* Lay's มตล Snack Corner — landing page
   Ratios are measured from design.png (1080x1920). All three assets sit at 1:1
   within that composition, so the percentages below are exact, not eyeballed. */

*,
*::before,
*::after {
  box-sizing: border-box;
}

html,
body {
  margin: 0;
  padding: 0;
}

body {
  /* The pink at the top of the artwork. Prevents a white flash if bg.png is
     slow or fails to load. Sampled from bg.png, do not change by eye. */
  background-color: #FFA5E8;
  font-family: system-ui, -apple-system, "Helvetica Neue", Arial, sans-serif;
  -webkit-text-size-adjust: 100%;
  overflow-x: hidden;
}

:root {
  /* The content column is exactly the CTA button's width. */
  --col: min(88vw, 460px);

  --pad-top:   clamp(20px, 4.9svh, 72px);   /* design: 95/1920  */
  --gap-logo:  clamp(28px, 9.7svh, 140px);  /* design: 186/1920 */
  --gap-badge: clamp(18px, 5.8svh, 84px);   /* design: 111/1920 */
}

.bg {
  position: fixed;
  inset: 0;
  z-index: 0;
}

.bg img {
  display: block;
  width: 100%;
  height: 100%;
  object-fit: cover;
  object-position: center;
}

.stage {
  position: relative;
  z-index: 1;

  /* svh, not vh: on iOS Safari vh resolves against the expanded viewport and
     pushes the CTA underneath the browser chrome. The vh line is the fallback
     for browsers that do not understand svh. */
  min-height: 100vh;
  min-height: 100svh;

  display: flex;
  flex-direction: column;
  align-items: center;

  padding-top:    calc(var(--pad-top) + env(safe-area-inset-top, 0px));
  padding-right:  calc(6vw + env(safe-area-inset-right, 0px));
  padding-bottom: calc(24px + env(safe-area-inset-bottom, 0px));
  padding-left:   calc(6vw + env(safe-area-inset-left, 0px));
}

.logo {
  display: block;
  width: calc(var(--col) * 0.208);  /* 190 / 913 */
  height: auto;
}

.badge {
  display: block;
  width: calc(var(--col) * 0.517);  /* 472 / 913 */
  height: auto;
  margin-top: var(--gap-logo);
}

.cta {
  display: block;
  width: var(--col);
  margin-top: var(--gap-badge);
  border-radius: 16px;
  transition: transform 120ms ease;
  -webkit-tap-highlight-color: transparent;
}

.cta img {
  display: block;
  width: 100%;
  height: auto;
}

.cta:active {
  transform: scale(0.97);
}

.cta:focus-visible {
  outline: 3px solid #FFFFFF;
  outline-offset: 4px;
}

@media (prefers-reduced-motion: reduce) {
  .cta {
    transition: none;
  }

  .cta:active {
    transform: none;
  }
}
```

- [ ] **Step 6: Run the smoke test to verify it passes**

```bash
npx playwright test tests/e2e/smoke.spec.ts
```

Expected: PASS — 7 tests, 0 failures.

- [ ] **Step 7: Write the visual regression test**

Create `tests/e2e/visual.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

const viewports = [
  { name: 'mobile', width: 390, height: 844 },
  { name: 'mobile-small', width: 320, height: 568 },
  { name: 'tablet', width: 768, height: 1024 },
  { name: 'desktop', width: 1440, height: 900 },
];

for (const vp of viewports) {
  test(`layout at ${vp.name} (${vp.width}x${vp.height})`, async ({ page }) => {
    await page.setViewportSize({ width: vp.width, height: vp.height });
    await page.goto('/');
    await page.waitForLoadState('networkidle');

    await expect(page).toHaveScreenshot(`${vp.name}.png`, {
      maxDiffPixelRatio: 0.01,
    });
  });
}
```

- [ ] **Step 8: Generate the baseline screenshots**

```bash
npx playwright test tests/e2e/visual.spec.ts --update-snapshots
```

Expected: 4 baseline PNGs written under `tests/e2e/visual.spec.ts-snapshots/`.

- [ ] **Step 9: Compare the baselines against the design**

Open `tests/e2e/visual.spec.ts-snapshots/mobile-chromium-darwin.png` beside `design.png` and confirm:

- the Lay's logo sits near the top, over the pink band
- the มตล badge sits over the yellow ellipse
- the CTA button sits at roughly the vertical middle, over the yellow/blue boundary
- nothing is clipped and nothing overlaps

If the vertical rhythm reads visibly differently from `design.png`, adjust only the three `clamp()` values in `:root` and re-run step 8. Do not change the width ratios — those are exact.

- [ ] **Step 10: Run the whole suite**

```bash
npm test
```

Expected: PASS — 31 bats tests and 11 Playwright tests.

- [ ] **Step 11: Commit**

```bash
git add site/index.html site/style.css playwright.config.ts tests/e2e/
git commit -m "feat: build landing page layout with smoke and visual tests"
```

---

### Task 5: `.htaccess`, deploy/provision/verify scripts, local Apache verification

> **Hosting change (2026-07-23):** this task originally targeted Cloudways. The
> campaign ships on a bare DigitalOcean Droplet instead — see
> `docs/superpowers/specs/2026-07-23-lays-snack-corner-landing-design.md` §9.0 for the
> decision and rationale. `deploy.sh` below is the DigitalOcean-retargeted version;
> `provision.sh` and `verify-deploy.sh` are new, added by this hosting change and not
> part of the original task scope. **This task is complete** — all of it runs and is
> verified locally (`tests/htaccess.bats` against real Apache 2.4.66,
> `tests/scripts.bats` for config-lint checks on the scripts themselves); nothing in
> it depends on a provisioned server existing yet. Task 6 covers the parts that do.

Everything through Task 4 runs locally against PHP's built-in dev server, which has no
`.htaccess`. This task adds the pieces needed to run for real — the Apache rewrite, the
cache headers, the provisioning script, the deploy script, and a post-deploy checklist —
and proves the parts that can be proven without a live server: `.htaccess` against a real
local Apache instance, and the scripts themselves via config-lint tests.

**Files:**
- Create: `site/.htaccess`
- Create: `deploy.sh`
- Create: `provision.sh`
- Create: `verify-deploy.sh`
- Create: `.env.deploy.example`
- Create: `tests/htaccess.bats`
- Create: `tests/scripts.bats`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: all of `site/` from Tasks 1–4
- Produces:
  - `site/.htaccess` — rewrites `/go` to `go.php`, sets cache headers, denies direct access to `link.txt`
  - `./provision.sh` — one-time (re-runnable) root setup of a fresh Ubuntu 24.04 Droplet: Apache 2.4 + PHP 8.3-FPM, the vhost (apex canonical, `www` redirects), the Cloudflare Origin Certificate, and a `ufw` firewall locked to Cloudflare's current IP ranges
  - `./deploy.sh` — rsyncs `site/` to the Droplet's document root, excluding `link.txt`
  - `./verify-deploy.sh <base-url>` — runs the full post-deploy checklist against either the public domain or the raw origin IP
  - `.env.deploy` (untracked) — holds `LAYS_REMOTE_HOST`, `LAYS_REMOTE_PATH`, `LAYS_SITE_URL`

- [x] **Step 1: Write `.htaccess`**

`site/.htaccess` — rewrites `/go` to `go.php`, denies direct access to `link.txt`, sets
the three-tier cache policy (`assets/*` cached a year immutable, `.html`/`.css`
`no-cache`), and disables directory listings. Unchanged by the hosting move — see the
next step for why that matters.

- [x] **Step 2: Verify `.htaccess` against real Apache locally**

`tests/htaccess.bats` starts a real local Apache 2.4 instance (not PHP's built-in dev
server) against a copy of `site/`, and asserts every behavior above through it,
including the one thing a hand-rolled PHP router cannot prove: that `RewriteRule
^go/?$ go.php [L]` for `/go/` (trailing slash) is evaluated before `mod_dir`'s
`DirectorySlash` handling, not after.

```bash
npx bats tests/htaccess.bats
```

Expected: `1..7`, all `ok`. This result — confirmed against real Apache 2.4.66 — is
exactly what makes it safe to move hosts without touching `.htaccess`: Apache is the
constant, and only the box underneath it changed.

- [x] **Step 3: Write `provision.sh`**

One-time (safely re-runnable) root provisioning for a fresh Ubuntu 24.04 Droplet.
Installs `apache2`, `php8.3-fpm`, `ufw`; enables `rewrite headers ssl proxy_fcgi
setenvif remoteip`; creates the document root; installs the Cloudflare Origin
Certificate from `/root/cloudflare-origin.{pem,key}`; writes the vhost with
`AllowOverride All` (§9.0/§9.4 of the design spec — without it `.htaccess` is silently
ignored); configures `mod_remoteip` so access logs show real visitor IPs; fetches
Cloudflare's current IPv4/IPv6 ranges and locks `ufw` to allow 80/443 from those ranges
only, adding the SSH allow rule *before* enabling `ufw` (getting that ordering wrong
permanently locks out the operator); enables unattended upgrades; and refuses to reload
Apache if `apache2ctl configtest` fails.

```bash
sudo ./provision.sh
```

(Run against a real Droplet in Task 6 — see there for expected output.)

- [x] **Step 4: Write the deploy script**

`deploy.sh` rsyncs `site/` to the Droplet's document root (`/var/www/laysmortorlor.com`,
matching `provision.sh`'s `DOCROOT`), excluding `link.txt` (operator state owned by
`set-link.sh`, not build output — an unexcluded `--delete` sync would silently revert
the live CTA to whatever is committed), forcing sane file modes
(`--chmod=D755,F644`) regardless of the deploying machine's local permissions, and then
SSHes in afterward to confirm/fix `link.txt`'s mode specifically (a `600` `link.txt` is
unreadable by `www-data` and makes every visitor silently get the fallback URL, with no
error in any log).

```bash
chmod +x deploy.sh   # already executable in the committed file; re-run is a no-op
```

- [x] **Step 5: Write `verify-deploy.sh`**

Post-deploy checklist. Runs every documented behavior against a `<base-url>` argument —
`/` 200, `/go` and `/go/` both 302 (never 301) to the current `site/link.txt` contents,
`/link.txt` 403, asset cache-forever headers, `/` `no-cache`, `/go` `no-store` plus
`cf-cache-status: BYPASS`, the `http://`→`https://` upgrade, the `www`→apex redirect, no
`/assets/` directory listing — and exits non-zero if any fail. Works against the public
domain or a raw origin IP (TLS verification is relaxed for the IP case, since the
Cloudflare Origin Certificate doesn't match a bare IP; the `cf-cache-status` check is
skipped, not failed, in that mode, since Cloudflare isn't in front of the request).

```bash
./verify-deploy.sh https://laysmortorlor.com     # through Cloudflare
./verify-deploy.sh https://<droplet-ip>          # raw origin, bypassing Cloudflare
```

(Run against a real Droplet in Task 6 — see there for expected output.)

- [x] **Step 6: Create the deployment config template**

`.env.deploy.example` — SSH target is the Droplet's IP directly (`root@YOUR_DROPLET_IP`,
found on the Droplet's page in the DigitalOcean control panel), the document root is
`provision.sh`'s `DOCROOT`, and the site URL is the apex (`https://laysmortorlor.com` —
canonical; `www` redirects to it, the reverse of the usual convention). No
Cloudways-style master/application account exists here.

- [x] **Step 7: Gitignore the real config**

`.env.deploy` appended to `.gitignore` — it holds real SSH credentials and must never be
committed.

- [x] **Step 8: Write the config-lint tests**

`tests/scripts.bats` — checks every top-level script (`provision.sh`, `deploy.sh`,
`verify-deploy.sh`, `set-link.sh`) exists, passes `bash -n`, is executable, and has the
right shebang; specifically pins the two failure modes that are otherwise invisible
until production: `provision.sh` adding the SSH allow rule *before* `ufw --force
enable` (by line number, not just string presence), and `AllowOverride All` being
present. Also asserts `provision.sh` never opens 80/443 to `0.0.0.0/0` or a bare `any`,
only to the fetched Cloudflare CIDR ranges, and aborts (rather than falling back) if the
Cloudflare IP-range fetch fails or fails validation.

```bash
npx bats tests/scripts.bats
```

Expected: all tests `ok`, 0 failures.

- [x] **Step 9: Run the full suite**

```bash
npm test
```

Expected: PASS — 71 bats tests (across `assets.bats`, `go.bats`, `set-link.bats`,
`htaccess.bats`, `scripts.bats`) and 11 Playwright tests, exit code 0.

- [x] **Step 10: Commit**

```bash
git add site/.htaccess deploy.sh provision.sh verify-deploy.sh .env.deploy.example \
  tests/htaccess.bats tests/scripts.bats .gitignore
git commit -m "feat: provision DigitalOcean Droplet and retarget deploy scripts"
```

---

### Task 6: Droplet, DNS, Cloudflare, and go-live

Puts a real Ubuntu 24.04 Droplet behind Cloudflare, proves the parts of Task 5 that
cannot be proven without one, and confirms the daily-update loop works end to end
against the live site.

**Already done, ahead of this task's remaining steps** (both shipped as part of
resolving the design spec's deferred values — see §12 of the design doc — independent
of which host was chosen):
- [x] Real domain (`laysmortorlor.com`, apex canonical) substituted into `site/index.html`'s Open Graph tags
- [x] `FALLBACK_URL` in `site/go.php` set to `https://www.instagram.com/laysthailand`, and the corresponding `tests/go.bats` fallback assertions updated to match

**Files:**
- Modify: `.env.deploy` (untracked — filled in with real values)

**Interfaces:**
- Consumes: `provision.sh`, `deploy.sh`, `verify-deploy.sh` from Task 5
- Produces: a live HTTPS site on a DigitalOcean Droplet, and a working `./set-link.sh <url>` against production

**Status: blocked.** Every step below requires a real DigitalOcean account, a real
Cloudflare zone for `laysmortorlor.com`, and a physical iPhone/Android — none of which
exist in this environment. Nothing below has been run against a real host.

- [ ] **Step 1: Create the Droplet**

DigitalOcean console → **Create → Droplets**. Image: **Ubuntu 24.04 (LTS) x64**.
Size: smallest tier is sufficient for a static page. Region: closest to the campaign
audience (Singapore for Thailand). Authentication: SSH key, not password.

Expected: a Droplet with a public IPv4 address, reachable via `ssh root@<droplet-ip>`.

- [ ] **Step 2: Point DNS at the Droplet through Cloudflare**

In the Cloudflare dashboard for `laysmortorlor.com`:

| Type | Name | Content | Proxy |
|---|---|---|---|
| A | `@` | Droplet IP | Proxied (orange) |
| A | `www` | Droplet IP | Proxied (orange) |

Apex is canonical here — double check the `@` record, not `www`, is the one campaign
traffic is expected to land on; this is the reverse of the usual setup and easy to get
backwards.

- [ ] **Step 3: Generate the Cloudflare Origin Certificate**

Cloudflare → **SSL/TLS → Origin Server → Create Certificate**. Private key type RSA
(2048), hostnames `laysmortorlor.com` and `*.laysmortorlor.com`, validity **15 years**.
Copy the **Origin Certificate** and the **Private Key** — the private key is shown
exactly once.

- [ ] **Step 4: Place the certificate and key on the Droplet**

```bash
scp origin-cert.pem root@<droplet-ip>:/root/cloudflare-origin.pem
scp origin-key.pem  root@<droplet-ip>:/root/cloudflare-origin.key
```

`provision.sh` refuses to run (Step 5) if either file is missing or empty at those exact
paths.

- [ ] **Step 5: Run `provision.sh`**

```bash
ssh root@<droplet-ip>
# on the Droplet:
git clone <this-repo> lays && cd lays   # or: scp/rsync provision.sh over on its own
sudo ./provision.sh
```

Expected: a sequence of `==>` progress lines ending in
`provisioning complete: https://laysmortorlor.com`, with `apache2ctl configtest`
passing and both `apache2` and `php8.3-fpm` restarted. If the origin certificate is
missing, `provision.sh` exits before touching Apache or `ufw` at all, with a message
naming the exact path it expected.

- [ ] **Step 6: Deploy**

From the local repo (not the Droplet):

```bash
cp .env.deploy.example .env.deploy
# edit .env.deploy: LAYS_REMOTE_HOST=root@<droplet-ip>
./deploy.sh
```

Expected: rsync's file list, then
`deployed site/ -> root@<droplet-ip>:/var/www/laysmortorlor.com/`, then
`verified: link.txt mode is sane on root@<droplet-ip>`.

- [ ] **Step 7: Verify the deploy**

```bash
./verify-deploy.sh "https://<droplet-ip>"   # raw origin, bypassing Cloudflare first
```

Expected: every check `[PASS]` except `GET /go carries cf-cache-status: BYPASS`, which
`[SKIP]`s in raw-IP mode (Cloudflare isn't in front of this request yet — DNS may not
even be proxied at this point). Ending line: `11 passed, 0 failed, 1 skipped`.

If `GET /go returns 302` fails with a 404, `AllowOverride All` is not in effect — see
the runbook's troubleshooting section.

- [ ] **Step 8: Set the Cloudflare SSL mode and add the cache-bypass rule**

1. **SSL/TLS → Overview → Full (strict).** Never Flexible — it leaves the
   Cloudflare-to-origin hop unencrypted despite the Origin Certificate from Step 3.
2. **SSL/TLS → Edge Certificates → Always Use HTTPS: On**
3. **SSL/TLS → Edge Certificates → Automatic HTTPS Rewrites: On**
4. **Caching → Cache Rules → Create rule** — name `Bypass cache for /go`, when incoming
   requests match `URI Path` `equals` `/go`, then **Bypass cache**, **Deploy**.

Then re-verify through the edge:

```bash
./verify-deploy.sh https://laysmortorlor.com
```

Expected: `11 passed, 0 failed, 0 skipped` — `cf-cache-status: BYPASS` on `/go` now
passes for real. If it reads `HIT` or `DYNAMIC` instead, the cache rule above is not
matching and the daily update will not take effect for visitors even though `go.php`
itself is correct.

- [ ] **Step 9: Prove the daily update loop end to end**

```bash
. ./.env.deploy
export LAYS_REMOTE_HOST LAYS_REMOTE_PATH LAYS_SITE_URL
./set-link.sh https://www.example.com/campaign-day-1
```

Expected:

```
local   : /Users/.../lay's/site/link.txt
reminder: site/link.txt has changed -- commit it, or a future redeploy will revert the live link
remote  : root@<droplet-ip>:/var/www/laysmortorlor.com/link.txt
verified: https://laysmortorlor.com/go -> https://www.example.com/campaign-day-1
```

The `verified:` line means the change is live at the edge. If it fails, the URL was
written but Cloudflare is still serving the old value — recheck Step 8's cache rule.
Commit the changed `site/link.txt` per the reminder line.

- [ ] **Step 10: Manual device pass**

Open `https://laysmortorlor.com` on a **real iPhone** and a **real Android phone**. No
emulator reproduces iOS Safari's viewport behavior faithfully, and that is the single
most likely thing to break this layout.

- [ ] the CTA button is fully visible without scrolling, with the Safari toolbar shown
- [ ] the CTA is still fully visible after scrolling collapses the toolbar
- [ ] tapping the CTA lands on today's destination
- [ ] the background fills the screen with no white edges
- [ ] on a notched device, nothing sits under the notch or the home indicator
- [ ] rotating to landscape does not clip the CTA

- [ ] **Step 11: Commit**

```bash
git add .env.deploy.example
git commit -m "chore: go live on laysmortorlor.com behind Cloudflare"
```

(`.env.deploy` itself stays untracked — only commit if something under version control
changed, e.g. the example template.)

---

## Post-Implementation Checklist

- [x] `npm test` passes — 71 bats tests, 11 Playwright tests
- [x] No occurrence of `REPLACE-WITH-DOMAIN` remains in `site/`
- [x] `.env.deploy` is untracked (`git status --ignored | grep .env.deploy`)
- [x] `docs/RUNBOOK.md` rewritten for DigitalOcean + Apache + Cloudflare, handed to whoever changes the link daily
- [ ] A real Droplet is provisioned and reachable
- [ ] `/go` returns `302` with `cf-cache-status: BYPASS` against the live domain
- [ ] `/link.txt` returns `403` against the live domain
- [ ] SSL mode is **Full (strict)**, not Flexible
- [ ] `./set-link.sh` verified against production at least once
- [ ] Manual pass done on a real iPhone and a real Android device
