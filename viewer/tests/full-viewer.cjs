const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright-core');
const assert=require('node:assert/strict');
(async()=>{const browser=await chromium.launch({args:['--no-sandbox']});try{
 const base=process.env.PROOF_ORIGIN||'http://127.0.0.1:8766';const page=await browser.newPage();const errors=[],urls=[];
 page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>urls.push(r.url()));
 await page.goto(base,{waitUntil:'domcontentloaded'});
 await page.waitForFunction(()=>document.querySelector('#live-video').videoWidth>=1280,{},{timeout:30000});
 await page.waitForFunction(()=>document.querySelectorAll('[data-clip]').length>0&&document.querySelector('[data-sensor="living"] .degrees').textContent.includes('°C'),{},{timeout:30000});
 assert.equal(await page.locator('[data-camera]').count(),2);assert.equal(await page.locator('[data-sensor]').count(),4);
 const list=await (await page.request.get(base+'/api/clips')).json();assert(list.clips.length>0&&list.clips.length<=9);assert.equal(await page.locator("[data-clip]").count(),list.clips.length);assert(list.clips.every((c,i)=>!i||list.clips[i-1].started>=c.started));
 assert.deepEqual([...new Set(list.clips.map(c=>c.camera))].sort(),['c200','c320']);
 for(const id of ['c200','c320']){
  await page.locator(`[data-camera="${id}"]`).click();await page.waitForFunction(id=>{const v=document.querySelector('#live-video');return v.videoWidth>=1280&&v.getAttribute('src').includes(id);},id,{timeout:30000});
  await page.waitForTimeout(1500);assert(await page.locator('#live-video').evaluate(v=>v.currentTime>0));
  console.log('PASS main stream',id,await page.locator('#live-video').evaluate(v=>[v.videoWidth,v.videoHeight]));
  const clip=list.clips.find(c=>c.camera===id);await page.locator(`[data-clip="${clip.id}"]`).click();await page.waitForFunction(()=>document.querySelector('#clip-video').readyState>=2,{},{timeout:30000});
  await page.locator('#clip-video').evaluate(async v=>{v.muted=true;await v.play();});await page.waitForTimeout(1200);assert(await page.locator('#clip-video').evaluate(v=>v.currentTime>0));
  await page.locator('#clip-video').evaluate(v=>{v.pause();v.currentTime=Math.min(3,v.duration/2);});await page.waitForFunction(()=>{const v=document.querySelector('#clip-video');return !v.seeking&&v.currentTime>.1;});
  await page.keyboard.press('Escape');assert(await page.locator('#clip-video').evaluate(v=>!v.hasAttribute('src')));
 }
 await page.locator('.tv-header .climate-toggle').click();assert(await page.locator('#climate-panel').isVisible());
 for(const id of ['living','bedroom','nest','outside']){
  await page.locator(`[data-sensor="${id}"] [data-room]`).click();await page.waitForFunction(()=>document.querySelector('#history-plots svg'),{},{timeout:20000});
  assert.equal(await page.locator('#history-plots .proof-graph').count(),id==='outside'?1:2);
  const max=await page.locator('#history-date').getAttribute('max');await page.locator('#history-date').fill(max);await page.locator('#history-date').dispatchEvent('change');await page.waitForFunction(()=>document.querySelector('#history-status').textContent.startsWith('Historik för'));
  await page.keyboard.press('Escape');
 }
 for(const [width,height] of [[1440,1000],[768,1024],[390,844]]){await page.setViewportSize({width,height});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));}
 await page.locator('#pause-live').click();assert.equal(await page.locator('#live-video').getAttribute('src'),null);await page.locator('#pause-live').click();await page.waitForFunction(()=>document.querySelector('#live-video').videoWidth>=1280,{},{timeout:25000});
 for(const route of ['/api/cameras/unknown/live.mp4','/api/history?room=unknown&date=24h','/api/history?date=24h&room=living&entity=sensor.other','/api/vod/unknown/index.m3u8']){assert((await page.request.get(base+route)).status()>=400);}
 assert(urls.every(u=>u.startsWith(base+'/')||u.startsWith('blob:'+base+'/')));assert.deepEqual(errors,[]);
 console.log('PASS: up to nine retained clips from both cameras; play/seek, four rooms and three humidities, 24h/date histories, phone/tablet/desktop, pause/reconnect and narrow same-origin API.');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
