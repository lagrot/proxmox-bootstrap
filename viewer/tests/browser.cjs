// Run with PLAYWRIGHT_MODULE pointing to an installed playwright-core package.
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright-core');
const assert = require('node:assert/strict');
const path = require('node:path');
(async () => {
 const browser = await chromium.launch({headless:true, args:['--no-sandbox']});
 try {
  const page = await browser.newPage(); const errors=[]; const external=[];
  page.on('pageerror', e=>errors.push(e.message));
  page.on('request', r=>{if(/^https?:/.test(r.url()))external.push(r.url());});
  const url='file://'+path.resolve(process.env.VIEWER_PAGE || path.resolve(__dirname,'../public/index.html'));
  await page.goto(url);
  assert.equal(await page.locator('[data-clip]').count(),12);
  assert.equal(await page.locator('img[src]').evaluateAll(imgs=>imgs.filter(i=>!i.complete || !i.naturalWidth).length),0);
  for(const [name,width,height] of [['desktop',1440,1000],['tablet',768,1024],['phone',390,844]]) {
   await page.setViewportSize({width,height});
   await page.locator('[data-view="kameror"]').click();
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
   await page.waitForTimeout(200);
   await page.screenshot({path:path.resolve(__dirname,`../artifacts/${process.env.DESIGN_NAME || ""}${name}-cameras.png`),fullPage:true});
   await page.locator('[data-view="temperatur"]').click();
   assert.equal(await page.locator('.climate-card:visible').count(),4);
   assert.equal(await page.locator('.humidity-value:visible').count(),3);
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
   await page.waitForTimeout(200);
   await page.screenshot({path:path.resolve(__dirname,`../artifacts/${process.env.DESIGN_NAME || ""}${name}-climate.png`),fullPage:true});
  }
  await page.locator('[data-history]').first().click();
  const before=await page.locator('#history-chart').innerHTML();
  await page.locator('#history-date').fill('2026-10-24');
  await page.locator('#history-date').dispatchEvent('change');
  assert.notEqual(await page.locator('#history-chart').innerHTML(),before);
  await page.locator('#history-date').fill('2026-10-28');
  await page.locator('#history-date').dispatchEvent('change');
  assert.match(await page.locator('#history-chart').textContent(),/giltigt datum/);
  await page.keyboard.press('Escape');
  await page.locator('[data-view="kameror"]').click();
  await page.locator('[data-camera]').first().click();
  assert(await page.locator('#media-dialog').evaluate(d=>d.open));
  await page.keyboard.press('Escape');
  assert(await page.locator('[data-camera]').first().evaluate(b=>b===document.activeElement));
  await page.locator('[data-clip]').first().click();
  await page.locator('#play-toggle').click(); await page.waitForTimeout(1200);
  assert.match(await page.locator('#player-time').textContent(),/00:01/);
  await page.locator('#play-toggle').click();
  await page.locator('#player-seek').fill('10'); await page.locator('#player-seek').dispatchEvent('input');
  assert.match(await page.locator('#player-time').textContent(),/00:10/);
  await page.keyboard.press('Escape');
  await page.goto(url+'?demo=empty');
  assert.equal(await page.locator('[data-clip]').count(),0);
  assert(await page.locator('.empty-message').isVisible());
  assert.deepEqual(errors,[]); assert.deepEqual(external,[]);
  console.log('PASS: offline images, 12 clips, three viewports, climate, date validation, dialogs, playback controls, keyboard focus, empty state; no external requests or JS errors.');
 } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exitCode=1;});
