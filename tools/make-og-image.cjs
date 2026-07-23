// Renders tools/og-image.html to site/assets/og-image.png at 1200x630.
//
//   npm run og:build
//
// Kept in the repo so the share card is reproducible from its source rather
// than being an unexplained binary. See tools/og-image.html for the rationale.

const path = require('path');
const { chromium } = require('@playwright/test');

const WIDTH = 1200;
const HEIGHT = 630;

const SOURCE = path.join(__dirname, 'og-image.html');
const OUTPUT = path.join(__dirname, '..', 'site', 'assets', 'og-image.png');

(async () => {
  const browser = await chromium.launch();

  try {
    const page = await browser.newPage({ viewport: { width: WIDTH, height: HEIGHT } });
    await page.goto('file://' + SOURCE);
    await page.waitForLoadState('networkidle');

    // Fail loudly rather than shipping a card with a missing image on it.
    const broken = await page.evaluate(() =>
      Array.from(document.images)
        .filter((img) => img.naturalWidth === 0)
        .map((img) => img.getAttribute('src')),
    );

    if (broken.length > 0) {
      throw new Error('asset(s) failed to load: ' + broken.join(', '));
    }

    await page.screenshot({ path: OUTPUT });
    console.log(`wrote ${OUTPUT} (${WIDTH}x${HEIGHT})`);
  } finally {
    await browser.close();
  }
})().catch((err) => {
  console.error('og:build failed —', err.message);
  process.exit(1);
});
