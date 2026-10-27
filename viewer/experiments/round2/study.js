/* Sample-only design studies. No backend or network requests. */
(() => {
'use strict';
const data=JSON.parse(document.querySelector('#study-data').textContent);
const C=window.LandetDemoCore, rooms=data.settings.locations, cameras=data.settings.cameras;
const clips=C.clips(cameras,data.settings.demo_date), app=document.querySelector('#app');
const $=s=>document.querySelector(s), esc=C.escape;
const date=new Intl.DateTimeFormat('sv-SE',{timeZone:'Europe/Stockholm',hour:'2-digit',minute:'2-digit'});
const image=id=>esc(data.images[id]);
const fmt=v=>C.format(v);
const photo=(id,cls='')=>`<img class="${cls}" src="${image(id)}" alt="Påhittad exempelbild: ${id==='garden'?'trädgården':'entrén'}" width="1600" height="900">`;
const graph=(points,key,large=false)=>{const p=C.coordinates(points,600,large?150:70,5);return `<svg viewBox="0 0 600 ${large?150:70}" preserveAspectRatio="none" role="img" aria-label="Temperaturens exempelkurva"><polyline points="${p.line}" fill="none" stroke="currentColor" stroke-width="2.5" vector-effect="non-scaling-stroke"/></svg>`;};
const spark=r=>graph(C.history(r,data.settings.demo_date).temperatures,r.id);
const climate=(r,compact=false)=>`<button class="sensor ${compact?'compact':''}" data-history="${r.id}" aria-label="${esc(r.name)}, ${fmt(r.temperature)} grader${r.humidity?', '+r.humidity+' procent luftfuktighet':''}. Visa historik"><span class="sensor-name">${esc(r.name)}</span><strong class="degrees">${fmt(r.temperature)}<small>°C</small></strong><span class="humidity">${r.humidity?'Luftfuktighet '+r.humidity+' %':'Utomhus · ingen fuktgivare'}</span>${spark(r)}<span class="graph-link">24 timmar · Välj datum ↗</span></button>`;
const camera=(id,cls='')=>{const cam=cameras.find(c=>c.id===id);return `<button class="camera ${cls}" data-camera="${id}" aria-label="Förstora ${cam.name}">${photo(id)}<span><b>${cam.name}</b><i>EXEMPELBILD</i><em>Förstora ↗</em></span></button>`;};
const clipButton=(c,cls='')=>`<button class="clip ${cls}" data-clip="${c.id}" aria-label="Öppna exempelklipp ${esc(c.name)} ${date.format(c.started)}"><span class="clip-photo">${photo(c.camera)}<i>▶ ${C.duration(c.duration)}</i></span><span class="clip-text"><b>${esc(c.name)}</b><time>${date.format(c.started)}</time></span></button>`;
const mark='<span class="wordmark">landet<span>•</span></span>';
if(data.mode==='huset'){
 app.innerHTML=`<header class="map-header">${mark}<div><p>EN PLATS ATT LANDA</p><h1>Hur är det hemma?</h1></div><span class="map-date">26 OKTOBER<br>Exempelöversikt</span></header><section class="estate" aria-label="Schematisk karta över huset och trädgården"><div class="garden-pattern" aria-hidden="true"></div><p class="map-caption">SCHEMATISK HUSKARTA · INTE DIN RIKTIGA PLANLÖSNING</p><div class="house"><div class="house-label">INOMHUS · TRYCK PÅ ETT RUM</div>${rooms.filter(r=>r.id!=='outside').map(r=>`<div class="room room-${r.id}">${climate(r)}</div>`).join('')}<div class="hall" aria-hidden="true">ENTRÉ<br>╎<br>╎</div></div><div class="outside-island">${climate(rooms.find(r=>r.id==='outside'))}</div><div class="map-camera garden-camera">${camera('garden')}</div><div class="map-camera entry-camera">${camera('entry')}</div><span class="north" aria-hidden="true">↑<br>N</span></section><section class="map-recordings"><div class="section-title"><div><p>DET SOM HÄNT</p><h2>12 senaste inspelningarna</h2></div><span>26 oktober · exempelklipp</span></div><div class="map-clips">${clips.map(c=>clipButton(c)).join('')}</div></section>`;
}else if(data.mode==='tv'){
 app.innerHTML=`<header class="tv-header">${mark}<span>ETT FÖNSTER TILL LANDET</span><button class="climate-toggle" aria-expanded="false">Temperatur & luftfuktighet ↗</button></header><section class="tv-stage"><div class="tv-picture"><img id="channel-image" src="${image('garden')}" alt="Påhittad exempelbild: trädgården" width="1600" height="900"><div class="tv-overlay"><span>EXEMPELBILD · INGEN LIVEANSLUTNING</span><h1 id="channel-title">Trädgården</h1></div><button class="tv-expand" data-camera="garden">Helskärm ↗</button></div><aside class="channel-picker"><p>VÄLJ KAMERA</p>${cameras.map((c,i)=>`<button class="channel ${i===0?'selected':''}" data-channel="${c.id}" aria-pressed="${i===0}"><span>0${i+1}</span>${photo(c.id)}<b>${c.name}</b></button>`).join('')}<div class="tv-climate-summary"><p>JUST NU · EXEMPEL</p>${rooms.map(r=>`<button data-history="${r.id}"><span>${r.name}</span><strong>${fmt(r.temperature)}°</strong><small>${r.humidity?r.humidity+' %':'Utomhus'}</small></button>`).join('')}</div></aside></section><section class="tv-recordings"><div class="section-title"><div><p>TITTA TILLBAKA</p><h2>Senaste inspelningarna</h2></div><div class="reel-controls"><button data-reel="-1" aria-label="Föregående inspelningar">←</button><button data-reel="1" aria-label="Nästa inspelningar">→</button></div></div><div class="film-reel" tabindex="0" aria-label="Tolv senaste exempelklipp, rulla åt sidan">${clips.map(c=>clipButton(c)).join('')}</div></section><section class="tv-climate-panel" id="climate-panel" hidden><div class="section-title"><h2>Klimatet, rum för rum</h2><button class="climate-toggle">Tillbaka till kamerorna ×</button></div><div class="tv-sensors">${rooms.map(r=>climate(r)).join('')}</div></section>`;
 document.querySelectorAll('[data-channel]').forEach(b=>b.addEventListener('click',()=>{
  const id=b.dataset.channel,cam=cameras.find(c=>c.id===id);
  $('#channel-image').src=data.images[id];$('#channel-image').alt='Påhittad exempelbild: '+cam.name;
  $('#channel-title').textContent=cam.name;$('.tv-expand').dataset.camera=id;
  document.querySelectorAll('[data-channel]').forEach(x=>{x.classList.toggle('selected',x===b);x.setAttribute('aria-pressed',x===b);});
 }));
 document.querySelectorAll('.climate-toggle').forEach(b=>b.addEventListener('click',()=>{
  const panel=$('#climate-panel');panel.hidden=!panel.hidden;
  $('.tv-header .climate-toggle').setAttribute('aria-expanded',!panel.hidden);
  if(!panel.hidden) panel.scrollIntoView({behavior:'smooth',block:'start'});
  else $('.tv-header .climate-toggle').focus();
 }));
 document.querySelectorAll('[data-reel]').forEach(b=>b.addEventListener('click',()=>$('.film-reel').scrollBy({left:Number(b.dataset.reel)*500,behavior:'smooth'})));
}else{
 app.innerHTML=`<header class="journal-header"><a class="journal-brand" href="#top">Landet / Dagboken</a><span>MÅNDAG 26 OKTOBER 2026 · EXEMPELDAG</span></header><section class="journal-intro" id="top"><div><p class="kicker">BORTA BRA. LANDET BÄST.</p><h1>Små ögonblick.<br>En plats du känner.</h1><p>En titt ut, det senaste som fångats och hur huset mår.</p></div><a class="skip-timeline" href="#timeline">Dagens 12 inspelningar ↓</a></section><div class="journal-layout"><div class="journal-main"><section class="live-strip"><div class="section-title"><h2>Just nu vid huset</h2><span>Två exempelbilder</span></div><div class="journal-cameras">${camera('garden')}${camera('entry')}</div></section><section id="timeline" class="timeline"><div class="timeline-heading"><span class="day-disc">26<small>OKT</small></span><div><p>HUSETS DAGBOK</p><h2>De senaste ögonblicken</h2><span>12 exempelklipp · nyast först</span></div></div>${clips.map((c,i)=>`<article class="timeline-event"><time>${date.format(c.started)}</time><div class="event-content"><p>${i===0?'Senaste inspelningen':c.camera==='garden'?'Ett ögonblick i trädgården':'En titt vid entrén'}</p>${clipButton(c)}<span class="event-caption">Exempelklipp · ${C.duration(c.duration)} · ${esc(c.name)}</span></div></article>`).join('')}</section></div><aside class="journal-climate"><p class="kicker">HUR MÅR HUSET?</p><h2>Varmt eller kallt?</h2><p>Tryck på ett rum för dagens kurvor och tidigare datum.</p><div class="journal-sensors">${rooms.map(r=>climate(r,true)).join('')}</div><div class="journal-note">Inga knappar för att styra hemmet.<br>Bara en lugn titt på landet.</div></aside></div>`;
}
app.insertAdjacentHTML('beforeend','<footer class="study-footer">Designstudie · Exempeldata · Ingen anslutning till ditt hem</footer>');
const dialog=$('#detail'), detail=$('#detail-content');let invoker=null,timer=null,seconds=0,current=null;
function stop(){clearInterval(timer);timer=null;}
function show(html,button){stop();invoker=button;detail.innerHTML=html;dialog.showModal();}
function close(){stop();if(document.fullscreenElement)document.exitFullscreen().catch(()=>{});dialog.close();invoker?.focus({preventScroll:true});}
$('.close-detail').addEventListener('click',close);
dialog.addEventListener('cancel',e=>{e.preventDefault();close();});
document.addEventListener('visibilitychange',()=>{if(document.hidden){stop();const b=$('#sample-play');if(b)b.textContent='Spela exempel ▶';}});
function media(id,button,clip){
 const cam=cameras.find(c=>c.id===id);seconds=0;current=clip;
 show(`<div class="detail-heading"><p>${clip?'SIMULERAT EXEMPELKLIPP':'PÅHITTAD EXEMPELBILD'}</p><h2>${cam.name}</h2></div>${photo(id,'detail-photo')}<button id="fullscreen" class="detail-action">Helskärm ↗</button>${clip?`<div class="sample-controls"><button id="sample-play" class="detail-action">Spela exempel ▶</button><output id="sample-time">00:00 / ${C.duration(clip.duration)}</output><label>Spola<input id="sample-seek" aria-label="Spola i exempelklippet" type="range" min="0" max="${clip.duration}" step="1" value="0"></label></div><p>Simulerad uppspelning av en stillbild. Ingen riktig inspelning.</p>`:''}`,button);
 $('#fullscreen').addEventListener('click',()=>dialog.requestFullscreen?.().catch(()=>{}));
 if(clip){
 const update=()=>{$('#sample-time').textContent=C.duration(seconds)+' / '+C.duration(clip.duration);$('#sample-seek').value=seconds;};
 $('#sample-play').addEventListener('click',()=>{if(timer){stop();$('#sample-play').textContent='Spela exempel ▶';return;}if(seconds>=clip.duration)seconds=0;$('#sample-play').textContent='Pausa ⏸';timer=setInterval(()=>{seconds=Math.min(seconds+1,clip.duration);update();if(seconds===clip.duration){stop();$('#sample-play').textContent='Spela exempel ▶';}},1000);});
 $('#sample-seek').addEventListener('input',e=>{seconds=Number(e.target.value);update();});
 }
}
function history(id,button){
 const r=rooms.find(x=>x.id===id);
 show(`<div class="detail-heading"><p>EXEMPELHISTORIK</p><h2>${r.name}</h2></div><label class="date-label">Välj datum <input id="study-date" type="date" value="${data.settings.demo_date}" max="${data.settings.demo_date}"></label><div id="plots"></div><p>Påhittade kurvor för att prova designen. Ingen sensorhistorik har hämtats.</p>`,button);
 const draw=()=>{const d=$('#study-date').value;if(!C.validDate(d)||d>data.settings.demo_date){$('#plots').textContent='Välj ett giltigt datum fram till 26 oktober 2026.';return;}const h=C.history(r,d);
 $('#plots').innerHTML=[['Temperatur',h.temperatures,'°C'],...(h.humidity.length?[['Luftfuktighet',h.humidity,'%']]:[])].map(([name,p,unit])=>`<section class="detail-plot"><h3>${name} <span>${fmt(Math.min(...p.map(v=>v.value)))}–${fmt(Math.max(...p.map(v=>v.value)))} ${unit}</span></h3>${graph(p,name,true)}<div class="axis"><span>00</span><span>06</span><span>12</span><span>18</span><span>24</span></div></section>`).join('');};
 $('#study-date').addEventListener('change',draw);draw();
}
app.addEventListener('click',e=>{
 const b=e.target.closest('button');if(!b)return;
 if(b.dataset.camera)media(b.dataset.camera,b);
 else if(b.dataset.clip){const c=clips.find(x=>x.id===b.dataset.clip);media(c.camera,b,c);}
 else if(b.dataset.history)history(b.dataset.history,b);
});
})();
