# Runbook — Lay's มตล Snack Corner

Stack: DigitalOcean Droplet (Ubuntu 24.04, Apache 2.4, PHP 8.3-FPM), fronted by
Cloudflare (proxied DNS, Origin Certificate, origin locked to Cloudflare's IP
ranges). Domain: apex `laysmortorlor.com` is canonical — `www` redirects to it.
This is the reverse of the usual setup; get it backwards and every check below
will look wrong for the wrong reason.

## Change today's CTA destination

```bash
. ./.env.deploy
export LAYS_REMOTE_HOST LAYS_REMOTE_PATH LAYS_SITE_URL
./set-link.sh https://today-destination.example.com/
```

Success ends with a `verified:` line. Anything else means the change is not live.

Only `https://` URLs with a dotted hostname are accepted. Rejected input leaves
the current live link untouched.

## Deploy a page change (copy, layout, images)

```bash
npm test              # must pass first
./deploy.sh
./verify-deploy.sh https://laysmortorlor.com
```

`deploy.sh` rsyncs `site/` to the Droplet's document root and never touches the
live `link.txt` (it is excluded on purpose — see the comment in `deploy.sh`).
`verify-deploy.sh` re-checks every behavior documented here — status codes,
cache headers, the `www`→apex redirect, the `/go` bypass — and exits non-zero
if anything regressed. Treat a deploy as incomplete until it passes.

Images are cached for a year. To swap one, change its **filename** and update
`index.html` — overwriting in place will not reach existing visitors.

## Check what is live right now

```bash
curl -sS -o /dev/null -w '%{http_code} -> %{redirect_url}\n' https://laysmortorlor.com/go
```

Or run the full checklist against production:

```bash
./verify-deploy.sh https://laysmortorlor.com
```

`verify-deploy.sh` also accepts the raw origin IP (`./verify-deploy.sh
https://<droplet-ip>`) to check Apache directly, bypassing Cloudflare — useful
when you need to tell whether a problem is at the origin or at the edge (see
below). In that mode it skips the `cf-cache-status` check, since Cloudflare
isn't in front of the request.

## Past link changes

`link-history.log` in the repo root, one tab-separated line per change
(UTC timestamp, URL). It is gitignored — local to whoever runs the script.

## Troubleshooting

Start here for any "button doesn't work" report:

```bash
curl -sSI https://laysmortorlor.com/go
```

Expect `302` and `cf-cache-status: BYPASS`. Then work through the failure
modes below — they are listed in the order you're likely to hit them, each
with how it looks from the outside.

### `/go` 404s, and `/link.txt` is readable (not 403)

**Cause:** `AllowOverride All` is not in effect on the Droplet's Apache vhost,
so `site/.htaccess` is being silently ignored — both the `/go` rewrite and the
`link.txt` deny rule stop working at once, with no error in any log.

**Check:**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://laysmortorlor.com/go        # expect 302, not 404
curl -sS -o /dev/null -w '%{http_code}\n' https://laysmortorlor.com/link.txt  # expect 403, not 200
```

Both wrong at once is the signature of this failure — a single symptom in
isolation usually means something else. Fix by re-running `sudo
./provision.sh` on the Droplet (it rewrites the vhost with `AllowOverride
All` unconditionally) and confirming `apache2ctl configtest` passes as part
of that run.

### `set-link.sh` reports `verified:` but visitors still see yesterday's link

**Cause:** the Cloudflare cache rule bypassing `/go` is missing or not
matching. `set-link.sh`'s verification step (and `verify-deploy.sh`) query
`$LAYS_SITE_URL/go` directly and can get a fresh response even while the edge
cache is serving a stale one to other visitors — the request path isn't
guaranteed to hit the same cache state a real visitor does.

**Check:**

```bash
curl -sSI https://laysmortorlor.com/go | grep -i cf-cache-status
```

Expect `BYPASS`. `HIT` or `DYNAMIC` means the rule isn't matching. Fix in
Cloudflare: **Caching → Cache Rules** — confirm a rule exists matching URI
Path equals `/go` with action **Bypass cache**, and that it is deployed (not
just saved as a draft).

### Every visitor gets the fallback (Instagram), and nothing errors anywhere

**Cause:** `link.txt` on the Droplet is unreadable by `www-data` — typically
mode `600` left over from a manual edit on the server (e.g. `cat >
link.txt`). `go.php` treats "unreadable" identically to "missing": it falls
back to `FALLBACK_URL` (`https://www.instagram.com/laysthailand`) and still
returns a clean `302`. There is no 500, no warning, nothing in the Apache
error log — from the outside this looks exactly like a deliberate fallback,
not a bug.

**Check:**

```bash
ssh "$LAYS_REMOTE_HOST" "stat -c '%a %U:%G' $LAYS_REMOTE_PATH/link.txt"
```

Expect `644 www-data:www-data`. Fix:

```bash
ssh "$LAYS_REMOTE_HOST" "chmod 644 $LAYS_REMOTE_PATH/link.txt"
```

`deploy.sh` already re-checks and fixes this mode on every deploy (it cannot
rsync `link.txt` itself — see above — but it `chmod`s it in place afterward),
so this should only happen after a manual edit on the box outside `deploy.sh`
and `set-link.sh`.

### Site is entirely unreachable (times out, connection refused)

**Cause:** Cloudflare periodically adds new IP ranges to its published
list. The Droplet's firewall (`ufw`) only allows port 80/443 from the
Cloudflare ranges that were current the last time `provision.sh` ran — a
range added since then is blocked at the firewall before it ever reaches
Apache.

**Check:** from a machine on the current internet (not required, but rules
this out fastest) compare the ranges `ufw` currently allows against
Cloudflare's published lists:

```bash
ssh "$LAYS_REMOTE_HOST" "ufw status numbered | grep -c cloudflare"
curl -s https://www.cloudflare.com/ips-v4 https://www.cloudflare.com/ips-v6 | wc -l
```

If the counts don't match (or the site was reachable yesterday and isn't
today with no other change), re-run provisioning — it re-fetches the current
ranges and replaces the firewall rules rather than accumulating them:

```bash
ssh "$LAYS_REMOTE_HOST"
sudo ./provision.sh
```

`provision.sh` is safe to re-run: it adds the SSH allow rule before touching
`ufw enable`, so this cannot lock you out, and it aborts without changing the
firewall at all if it can't fetch or validate Cloudflare's current ranges.

### `go.php` itself is broken (500, or /go doesn't come back at all)

`go.php` is designed to never 500 — a missing, empty, or malformed
`link.txt` all fall back cleanly. A `500` here means the deploy itself is
broken (a PHP syntax error, or PHP-FPM down). Re-run:

```bash
./deploy.sh
./verify-deploy.sh https://laysmortorlor.com
```

If PHP-FPM is the problem specifically:

```bash
ssh "$LAYS_REMOTE_HOST" "sudo systemctl status php8.3-fpm"
```

## Where the origin certificate lives

The Cloudflare Origin Certificate is issued for 15 years and installed by
`provision.sh` at:

- Certificate: `/etc/ssl/certs/cloudflare-origin.pem` (mode `644`)
- Private key: `/etc/ssl/private/cloudflare-origin.key` (mode `600`)

It is generated once, by hand, in the Cloudflare dashboard (**SSL/TLS →
Origin Server → Create Certificate**) and placed on the Droplet at
`/root/cloudflare-origin.pem` / `.key` before the first `provision.sh` run —
`provision.sh` reads from there and installs it to the paths above. At a
15-year validity there is no routine renewal to schedule; note the issue date
somewhere durable (this file is as good a place as any) so a future operator
isn't caught by surprise near 2041.

Cloudflare's SSL/TLS mode must be **Full (strict)** — never **Flexible**.
Flexible leaves the Cloudflare-to-origin hop unencrypted even though the
origin certificate above exists specifically to encrypt it.
