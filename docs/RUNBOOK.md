# Runbook — Lay's มตล Snack Corner

## Change today's CTA destination

```bash
. ./.env.deploy
export LAYS_REMOTE_HOST LAYS_REMOTE_PATH LAYS_SITE_URL
./set-link.sh https://today-destination.example.com/
```

Success ends with a `verified:` line. Anything else means the change is not live.

Only `https://` URLs with a dotted hostname are accepted. Rejected input leaves
the current live link untouched.

## Change the page itself (copy, layout, images)

```bash
npm test        # must pass first
./deploy.sh
```

Images are cached for a year. To swap one, change its **filename** and update
`index.html` — overwriting in place will not reach existing visitors.

## Check what is live right now

```bash
curl -sS -o /dev/null -w '%{http_code} -> %{redirect_url}\n' https://laysmortorlor.com/go
```

## Past link changes

`link-history.log` in the repo root, one tab-separated line per change
(UTC timestamp, URL). It is gitignored — local to whoever runs the script.

## If the button goes nowhere

1. `curl -sSI https://laysmortorlor.com/go` — expect `302` and `cf-cache-status: BYPASS`
2. `cf-cache-status: HIT` means the Cloudflare cache rule for `/go` is not
   matching. Fix it in Caching -> Cache Rules.
3. A `500` means `go.php` is broken. It is designed never to 500 — it falls back
   instead — so this indicates a bad deploy. Re-run `./deploy.sh`.
4. Landing on the fallback URL means `link.txt` is missing or invalid on the
   server. Re-run `./set-link.sh` with today's URL.
