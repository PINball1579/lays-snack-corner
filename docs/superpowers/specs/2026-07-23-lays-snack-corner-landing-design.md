# Lay's "มตล Snack Corner" Landing Page — Design

**Date:** 2026-07-23
**Status:** Approved

## 1. Goal

A single-page, mobile-first campaign landing page carrying three visual elements over a
full-bleed background, with one call-to-action whose destination URL changes daily.

Hosted on Cloudways, fronted by Cloudflare with SSL.

## 2. Non-goals

These are explicitly out of scope:

- Any multi-page structure, routing, or navigation
- In-browser photo upload, compositing, or template generation
- A CMS, admin UI, or login of any kind
- Analytics or tracking (a hook point is noted, nothing is implemented)
- A JavaScript build step, bundler, or framework

## 3. Stack

Plain static HTML + CSS, with a single PHP file for the CTA redirect. No build step.

Deployed to a Cloudways **PHP Stack** application, whose `public_html/` is an
Apache/Nginx document root that serves static files directly. PHP is present on that
stack by default and is used for exactly one purpose (§7).

**Rationale.** The page is three images and roughly 100 lines of CSS. A bundler would
add asset hashing (solving a cache-busting problem a four-file site does not have) and
put a `dist/` build between the author and every one-word copy change. A static-site
framework would install a large Node toolchain to render three `<img>` tags. Neither
earns its keep here.

## 4. File structure

```
lay's/
├── design.png                  reference only — not deployed
├── material/                   source assets — not deployed
├── site/                       ← contents deploy to public_html/
│   ├── index.html
│   ├── style.css
│   ├── go.php
│   ├── link.txt
│   ├── .htaccess
│   ├── favicon.png
│   └── assets/
│       ├── bg.png
│       ├── logo-lays.png
│       ├── logo-mtr.png
│       ├── btn-add-template.png
│       └── og-image.png
├── set-link.sh                 CLI helper for the daily URL change
├── link-history.log            append-only record of link changes
├── tests/
└── docs/superpowers/specs/
```

Source files in `material/` are never modified. Assets are **copied** into
`site/assets/` under web-safe names.

### 4.1 Asset rename map

| Source | Destination | Size |
|---|---|---|
| `material/bg.png` | `site/assets/bg.png` | 1080×1920 |
| `material/logo.png` | `site/assets/logo-lays.png` | 190×179 |
| `material/mtr.png` | `site/assets/logo-mtr.png` | 472×274 |
| `material/add your.png` | `site/assets/btn-add-template.png` | 913×280 |
| `design.png` | `site/assets/og-image.png` | 1080×1920 |

`add your.png` contains a space, which is invalid in a URL without escaping. Renaming
it is mandatory, not cosmetic.

## 5. Page structure

```html
<div class="bg">      <!-- position:fixed; inset:0; z-index:0; aria-hidden="true" -->
  <img src="assets/bg.png">   <!-- object-fit:cover -->
</div>

<main class="stage">  <!-- min-height:100svh; flex column; align-items:center; z-index:1 -->
  <img class="logo"  src="assets/logo-lays.png" alt="Lay's">
  <img class="badge" src="assets/logo-mtr.png"  alt="มตล ใหม่ ต้องลอง — Snack Corner">
  <a   class="cta"   href="/go" aria-label="Add your template">
    <img src="assets/btn-add-template.png" alt="">
  </a>
</main>
```

No JavaScript. The CTA is a plain anchor: it functions with JS disabled, it is
crawlable, and middle-click / long-press "open in new tab" behave natively.

The button is used as its supplied PNG rather than rebuilt in CSS. The asset already
contains its white ring and drop shadow, the source is ~2× its display size, and this
removes any dependency on sourcing a matching heavy condensed typeface. The `alt` is
empty because the parent anchor carries the accessible name.

## 6. Layout and responsive behavior

### 6.1 Content column

All three assets are exported at exactly their composition size within the 1080×1920
design, so the design yields exact ratios. Content sits in a centered column whose width
equals the button's:

```css
--col: min(88vw, 460px);
```

| Element | Width | Derivation |
|---|---|---|
| Lay's logo | 20.8% of `--col` | 190 / 913 |
| มตล badge | 51.7% of `--col` | 472 / 913 |
| CTA button | 100% of `--col` | 913 / 913 |

### 6.2 Vertical rhythm

Measured from the design (1080×1920), expressed as a share of viewport height:

| Gap | Design px | Share | CSS |
|---|---|---|---|
| top → logo | 95 | 4.9% | `clamp(20px, 4.9svh, 72px)` |
| logo → badge | 186 | 9.7% | `clamp(28px, 9.7svh, 140px)` |
| badge → button | 111 | 5.8% | `clamp(18px, 5.8svh, 84px)` |
| button → bottom | 795 | 41.4% | implicit remainder |

The column is top-aligned inside a `100svh` flex container, so the space below the
button is whatever remains — no explicit spacer element. On a tall phone this lands the
button near the vertical middle, matching the design. `clamp()` bounds keep the layout
from collapsing on a short viewport (landscape phone, small laptop) or over-stretching
on a tall one.

These values are starting points. Implementation tunes them against a screenshot
comparison with `design.png` at 390×844 and 1440×900.

### 6.3 Viewport units

Heights use `svh` / `dvh`, never plain `vh`. On iOS Safari `vh` resolves against the
*expanded* viewport, which pushes the button underneath the browser chrome — the single
most likely way this layout breaks on a real device.

Padding respects `env(safe-area-inset-*)` for notched devices.

### 6.4 Desktop

The background fills the viewport with `object-fit: cover`, cropping top and bottom on
wide screens. Content stays in the centered `--col`. No letterboxing, no distortion.

### 6.5 Tap target

The CTA's tap area is the full 913×280 image — far above the 44px minimum.

## 7. CTA redirect subsystem

The destination URL changes daily. It therefore does not live in the HTML.

### 7.1 Design

The button points at `/go` permanently. `go.php` reads `link.txt`, validates it, and
issues a `302` to that URL.

```
tap → /go → go.php reads link.txt → 302 → destination
```

This keeps the public URL stable forever, so any link already printed, posted, or sent
to partners keeps working regardless of where it points today.

**The status code must be `302`, never `301`.** A `301` is a permanent redirect that
browsers cache aggressively and often indefinitely — on a destination that changes daily
it would strand returning visitors on a stale URL with no way to clear it short of
asking them to wipe their browser cache.

### 7.2 Daily update

```sh
./set-link.sh https://today.example.com/campaign
```

**Execution model.** `set-link.sh` runs **locally**, from the repo root. On a valid URL
it:

1. writes the local `site/link.txt`
2. writes the remote `public_html/link.txt` over SSH
3. appends a dated entry to the local `link-history.log`
4. verifies by requesting `https://<domain>/go` and asserting the `Location` header
   matches

Keeping the local and remote copies in step means a later full redeploy of `site/` never
silently reverts the live link to an older value — a failure mode that would otherwise be
invisible until someone tapped the button.

`link-history.log` stays local and is never deployed.

Update latency is under a second. No upload, no rebuild, no dashboard.

### 7.3 Caching

`go.php` responds with `Cache-Control: no-store`. A Cloudflare Cache Rule bypasses cache
on `/go`. Without both, the edge will serve yesterday's destination for hours.

### 7.4 Security

**`go.php` reads its destination only from the server-side `link.txt`. It must never
accept a URL from a query parameter, path segment, header, or cookie.**

A redirect endpoint that takes its target from user input is an open redirect, and on a
page carrying Lay's branding that is a phishing vector aimed at the brand. The file has
exactly one input and that input is a file under our control.

`set-link.sh` rejects any scheme other than `https`, rejects malformed URLs, and rejects
empty input.

`link.txt` lives inside `public_html/` and would otherwise be readable at
`https://<domain>/link.txt`. `.htaccess` denies direct access to it. The contents are not
secret, but exposing the raw config file invites people to poll it and serves no purpose.

## 8. Error handling

There is almost no runtime logic, so error handling here means asset and network failure
modes:

- `<body>` carries a background color matching the artwork's pink, so a slow or failed
  `bg.png` never flashes white
- `bg.png` is `<link rel="preload">`ed — it is the largest paint
- every `<img>` has explicit `width` / `height` (zero cumulative layout shift) and
  meaningful `alt`
- **if `link.txt` is missing, empty, or fails validation, `go.php` falls back to a
  hardcoded default URL and still returns a `302`** — it must never return a 500. A
  broken deploy cannot be allowed to turn the only button on the page into an error
  screen.
- `<meta property="og:image">` points at `assets/og-image.png`, so links pasted into
  LINE, Messenger, or X unfurl with the campaign art

## 9. Deployment

### 9.1 Cloudways

1. Launch a server (smallest tier is sufficient), application type **PHP Stack**
2. Upload `site/*` to `public_html/` via SFTP, or connect the git repo and use
   Cloudways' git deployment
3. Add the domain under **Application → Domain Management** as the primary domain

### 9.2 Cloudflare

1. `A` record for the domain → Cloudways server IP, **proxied** (orange cloud)
2. Generate a **Cloudflare Origin Certificate** (15-year) and install it as a custom SSL
   certificate in Cloudways
3. SSL/TLS mode → **Full (strict)**
4. Enable **Always Use HTTPS** and **Automatic HTTPS Rewrites**
5. Add a **Cache Rule**: bypass cache on path `/go`

An Origin Certificate is used rather than Let's Encrypt because LE's HTTP-01 validation
and its 90-day auto-renew can both fail behind Cloudflare's proxy unless `/.well-known/`
is specifically excluded from caching. The Origin Certificate removes that failure mode
for the life of the campaign.

### 9.3 Cache headers (`.htaccess`)

| Path | `Cache-Control` |
|---|---|
| `/assets/*` | `public, max-age=31536000, immutable` |
| `/index.html`, `/style.css` | `no-cache` |
| `/go` | `no-store` |

`.htaccess` additionally denies direct HTTP access to `link.txt` (§7.4).

Consequence: replacing an image requires a filename change, but copy and CSS edits go
live immediately.

## 10. Testing

The static page has no branches, so line coverage over it would be a vacuous 100%. The
redirect subsystem does have logic, and that is where tests carry weight.

**Unit — `set-link.sh` validation**
- rejects `http://` (non-TLS)
- rejects a malformed URL
- rejects empty input
- accepts a valid `https://` URL and writes `link.txt`
- appends to `link-history.log` on success

**Unit — `go.php` fallback**
- valid `link.txt` → `302` to that URL
- missing `link.txt` → `302` to the fallback, not a 500
- empty `link.txt` → `302` to the fallback
- malformed contents → `302` to the fallback
- a URL supplied via query string is ignored (open-redirect guard)
- the response status is `302`, not `301`

**Smoke — Playwright**
- page returns 200 with no console errors
- all four images load with `naturalWidth > 0` (catches the renamed-asset bug class)
- `.cta` href is `/go`, and the anchor is visible without scrolling at 390×844
- `/go` returns `302` to the current `link.txt` value
- screenshots at 390×844, 768×1024, 1440×900 for visual review

**Manual** — one pass on a real iPhone and a real Android device. Safari's viewport
behavior is the most likely thing to break this layout and no emulator reproduces it
faithfully.

## 11. Known trade-offs

**Background resolution.** `bg.png` is 1080×1920. Covering a 2560px-wide desktop
upscales it about 2.4×, softening the curved edges of the yellow circle and the star.
The shapes are large and flat, so it reads as mild blur rather than pixelation, and
mobile — the priority — is unaffected. If desktop crispness matters, an SVG or 2× export
from the designer drops in as a one-line change.

**Button text is not live text.** Using the supplied PNG means the CTA copy is not
selectable or translatable. Accepted: the anchor carries an `aria-label`, and on a
three-element page the cost is nil.

**PHP for one file.** The site is not purely static. This is ~15 lines on a stack that
already runs PHP, bought in exchange for a one-command daily update with no JS
dependency and no race between page load and href assignment.

## 12. Open items

Both are non-blocking; implementation uses placeholders.

| Item | Placeholder | Needed by |
|---|---|---|
| Fallback URL for `go.php` | `/` (the site's own root) | before go-live |
| Domain name | — | Cloudways + Cloudflare setup |

The daily CTA URL is supplied by the user each day via `set-link.sh` and needs no
placeholder.
