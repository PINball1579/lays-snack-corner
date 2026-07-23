import { test, expect } from '@playwright/test';

const MOBILE = { width: 390, height: 844 };

const GTM_ID = 'GTM-MV8VFGPS';

// Stub Google Tag Manager rather than letting it load for real. Without this
// the suite silently depends on googletagmanager.com being reachable: offline,
// or in CI without egress, the fetch fails and the "no console errors" test
// breaks for a reason that has nothing to do with this site. We control the
// snippet, not Google's CDN, so the snippet is what we assert on (see the
// GTM test below). Fulfilled empty rather than aborted, because an aborted
// script load logs a network error to the console.
test.beforeEach(async ({ page }) => {
  await page.route('**://www.googletagmanager.com/**', (route) =>
    route.fulfill({ status: 200, contentType: 'application/javascript', body: '' }),
  );
});

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

test('Google Tag Manager snippet is installed correctly', async ({ page }) => {
  await page.goto('/');
  const html = await page.content();

  // Head snippet: must carry the right container and load gtm.js.
  expect(html).toContain(GTM_ID);
  expect(html).toContain('googletagmanager.com/gtm.js');

  // charset must stay the very first meta: it has to land in the first 1024
  // bytes or the browser may guess the encoding and mangle the Thai text.
  const charsetIndex = html.indexOf('charset');
  const gtmIndex = html.indexOf('gtm.start');
  expect(charsetIndex).toBeGreaterThan(-1);
  expect(gtmIndex).toBeGreaterThan(charsetIndex);

  // noscript fallback must be immediately inside <body>, not in <head>.
  const bodyIndex = html.indexOf('<body');
  const noscriptIndex = html.indexOf('googletagmanager.com/ns.html');
  expect(noscriptIndex).toBeGreaterThan(bodyIndex);

  // dataLayer must actually be initialized by the snippet.
  const hasDataLayer = await page.evaluate(() => Array.isArray((window as any).dataLayer));
  expect(hasDataLayer).toBe(true);
});

test('the CTA still works with GTM present', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('a.cta')).toHaveAttribute('href', '/go');

  const response = await page.request.get('/go', { maxRedirects: 0 });
  expect(response.status()).toBe(302);
  expect(response.headers()['location']).toBe('https://www.instagram.com/laysthailand');
});
