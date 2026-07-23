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
