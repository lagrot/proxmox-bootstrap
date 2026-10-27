const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright-core');
const assert=require('node:assert/strict');const path=require('node:path');
(async()=>{const browser=await chromium.launch({args:['--no-sandbox']});try{
 for(const mode of ['huset','tv','dagboken']){
  const page=await browser.newPage();const errors=[],network=[];page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>{if(/^https?:/.test(r.url()))network.push(r.url());});
  await page.goto('file://'+path.resolve(__dirname,`../artifacts/designs-v2/${mode}/index.html`));
  assert.equal(await page.locator('[data-clip]').count(),12);
  for(const [name,width,height] of [['desktop',1440,1000],['tablet',768,1024],['phone',390,844]]){
   await page.setViewportSize({width,height});
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`${mode} ${name} overflow`);
   assert.equal(await page.locator('img[src]').evaluateAll(imgs=>imgs.filter(i=>!i.complete||!i.naturalWidth).length),0);
   await page.screenshot({path:path.resolve(__dirname,`../artifacts/v2-${mode}-${name}.png`),fullPage:true});
  }
  if(mode==='tv'){
   await page.locator('[data-channel="entry"]').click();assert.equal(await page.locator('#channel-title').textContent(),'Entrén');
   await page.locator('.tv-header .climate-toggle').click();assert(await page.locator('#climate-panel').isVisible());
   assert.equal(await page.locator('#climate-panel .sensor').count(),4);
   await page.locator('#climate-panel .climate-toggle').click();
  }
  const history=page.locator('[data-history]').first();await history.click();
  assert(await page.locator('#detail').evaluate(d=>d.open));
  const before=await page.locator('#plots').innerHTML();await page.locator('#study-date').fill('2026-10-24');await page.locator('#study-date').dispatchEvent('change');assert.notEqual(await page.locator('#plots').innerHTML(),before);
  await page.locator('#study-date').fill('2026-10-28');await page.locator('#study-date').dispatchEvent('change');assert.match(await page.locator('#plots').textContent(),/giltigt datum/);
  await page.keyboard.press('Escape');assert(await history.evaluate(b=>b===document.activeElement));
  await page.locator('[data-camera]').first().click();assert(await page.locator('.detail-photo').isVisible());await page.locator('.close-detail').click();
  await page.locator('[data-clip]').first().click();await page.locator('#sample-play').click();await page.waitForTimeout(1100);assert.match(await page.locator('#sample-time').textContent(),/00:01/);await page.locator('#sample-play').click();
  await page.locator('#sample-seek').fill('10');await page.locator('#sample-seek').dispatchEvent('input');assert.match(await page.locator('#sample-time').textContent(),/00:10/);await page.keyboard.press('Escape');
  assert.deepEqual(errors,[]);assert.deepEqual(network,[]);console.log('PASS '+mode+': 12 clips, images, three viewports, dates/errors, camera dialog, playback simulation, focus and zero network requests.');await page.close();
 }
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
