// Small HA cards: sensor history and recorded clips, with same-origin HA APIs only.
export function safeMediaPath(value, origin) {
  const url = new URL(value, origin);
  if (url.origin !== origin || !url.pathname.startsWith('/api/frigate/') || url.username || url.password) {
    throw new Error('Media must use the Home Assistant Frigate proxy');
  }
  return url.pathname + url.search;
}

export function calendarRange(day, zone) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error('Invalid date');
  const [y, m, d] = day.split('-').map(Number);
  const target = Date.UTC(y, m - 1, d);
  if (new Date(target).toISOString().slice(0, 10) !== day) throw new Error('Invalid date');
  const format = new Intl.DateTimeFormat('en-GB', {
    timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
  });
  function midnight(wanted) {
    let guess = wanted;
    for (let i = 0; i < 3; i++) {
      const p = Object.fromEntries(format.formatToParts(new Date(guess)).map(x => [x.type, x.value]));
      guess += wanted - Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second);
    }
    return new Date(guess);
  }
  return [midnight(target), midnight(Date.UTC(y, m - 1, d + 1))];
}

export function historyPoints(rows, start, end) {
  return rows.map(row => ({time: Date.parse(row.last_changed || row.last_updated),
    value: row.state === '' || row.state == null ? NaN : Number(row.state)}))
    .filter(row => Number.isFinite(row.time) && Number.isFinite(row.value) && row.time <= end)
    .map(row => ({...row, time: Math.max(start, row.time)})).sort((a, b) => a.time - b.time);
}

export function recentClips(result, cameras) {
  const events = typeof result === 'string' ? JSON.parse(result) : result;
  if (!Array.isArray(events)) throw new Error('Invalid event list');
  return events.filter(e => cameras.includes(e.camera) && e.has_clip !== false && e.end_time != null
    && Number.isFinite(Number(e.start_time)) && /^[A-Za-z0-9][A-Za-z0-9_.-]{1,100}$/.test(e.id)
    && !e.id.includes('..'))
    .sort((a, b) => Number(b.start_time) - Number(a.start_time)).slice(0, 10);
}

const escape = value => String(value).replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const styles = `
  :host{display:block;color:var(--primary-text-color)}ha-card{padding:18px}
  h2{font-size:20px;margin:0 0 16px}p{margin:8px 0}.value{font-size:30px;font-weight:650}
  .muted{color:var(--secondary-text-color);font-size:14px}.values{display:flex;gap:28px;flex-wrap:wrap}
  button,input{font:inherit;color:inherit}button{cursor:pointer;border:1px solid var(--divider-color,#555);border-radius:10px;background:var(--secondary-background-color,#222);padding:12px;min-height:48px}
  button:focus-visible,input:focus-visible{outline:3px solid var(--primary-color,#03a9f4)}
  .history{display:block;width:100%;text-align:left;margin-top:14px;background:transparent}
  svg{display:block;width:100%;height:72px}.large svg{height:180px}polyline{fill:none;stroke-width:2;vector-effect:non-scaling-stroke}
  dialog{color:var(--primary-text-color,#eee);background:var(--card-background-color,#1c1c1c);border:1px solid var(--divider-color,#555);border-radius:14px;width:min(820px,calc(100vw - 40px));max-height:90vh;overflow:auto;padding:20px;box-sizing:border-box}
  dialog::backdrop{background:#000b}.toolbar{display:flex;align-items:center;justify-content:space-between;gap:14px;flex-wrap:wrap}
  input{background:var(--secondary-background-color,#222);border:1px solid var(--divider-color,#555);padding:12px;border-radius:8px}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(190px,100%),1fr));gap:12px}
  .clip{text-align:left;padding:0;overflow:hidden}.clip img{width:100%;aspect-ratio:16/9;object-fit:cover;display:block;background:#111}.clip span{display:block;padding:10px}
  video{display:block;width:100%;max-height:65vh;background:#000;margin-top:16px}
`;

function chart(points, start, end, color, title) {
  if (!points.length) return `<p class="muted">Ingen historik för ${escape(title.toLowerCase())}</p>`;
  let low = Math.min(...points.map(p => p.value)), high = Math.max(...points.map(p => p.value));
  if (low === high) { low -= 1; high += 1; }
  const coords = points.map(p => `${8 + (p.time - start) / (end - start) * 584},${74 - (p.value - low) / (high - low) * 66}`).join(' ');
  return `<div class="muted">${escape(title)}</div><svg viewBox="0 0 600 82" preserveAspectRatio="none" role="img" aria-label="${escape(title)}"><polyline stroke="${color}" points="${coords}"/></svg>`;
}

class LandetClimateCard extends HTMLElement {
  constructor() { super(); this.attachShadow({mode: 'open'}); this._last = 0; this._loading = false; this._request = 0; }
  setConfig(config) { this._config = config; }
  connectedCallback() {
    if (this._hass) this.loadPreview();
    this._timer = setInterval(() => { if (this._hass && !this._loading) this.loadPreview(); }, 60000);
  }
  set hass(hass) {
    this._hass = hass;
    if (!this.shadowRoot.firstChild) this.build();
    this.updateValues();
    if (this.isConnected && Date.now() - this._last > 60000 && !this._loading) this.loadPreview();
  }
  getCardSize() { return this._config.humidity ? 5 : 4; }
  disconnectedCallback() { clearInterval(this._timer); this._request++; this.shadowRoot.querySelector('dialog')?.close(); }
  build() {
    const c = this._config;
    this.shadowRoot.innerHTML = `<style>${styles}</style><ha-card><h2>${escape(c.name)}</h2><div class="values"><div><div class="muted">Temperatur</div><div class="value temp"></div></div>${c.humidity ? '<div><div class="muted">Luftfuktighet</div><div class="value humidity"></div></div>' : ''}</div><button class="history" aria-label="Visa historik och välj datum"><div class="preview"></div><div class="muted">Senaste 24 timmarna · Tryck för datum</div></button><p class="muted">${escape(c.location)}</p></ha-card><dialog aria-label="Historik"><div class="toolbar"><h2>${escape(c.name)}</h2><button class="close">Stäng</button></div><label>Välj datum <input type="date"></label><p class="muted range"></p><div class="large"></div></dialog>`;
    const dialog = this.shadowRoot.querySelector('dialog');
    this.shadowRoot.querySelector('.close').onclick = () => dialog.close();
    this.shadowRoot.querySelector('.history').onclick = () => {
      const input = dialog.querySelector('input');
      const parts = Object.fromEntries(new Intl.DateTimeFormat('en-GB', {timeZone: this.zone(), year: 'numeric', month: '2-digit', day: '2-digit'}).formatToParts(new Date()).map(p => [p.type, p.value]));
      input.max = input.value = `${parts.year}-${parts.month}-${parts.day}`;
      dialog.showModal(); this.loadDate(input.value);
    };
    dialog.querySelector('input').onchange = event => this.loadDate(event.target.value);
    dialog.onclick = event => { if (event.target === dialog) dialog.close(); };
  }
  zone() { return this._hass.config.time_zone || 'Europe/Stockholm'; }
  updateValues() {
    for (const [key, unit] of [['temperature', '°C'], ['humidity', '%']]) {
      const node = this.shadowRoot.querySelector(key === 'temperature' ? '.temp' : '.humidity');
      if (!node) continue;
      const state = this._hass.states[this._config[key]]?.state;
      const value = state == null || state === '' ? NaN : Number(state);
      node.textContent = Number.isFinite(value) ? `${new Intl.NumberFormat('sv-SE', {maximumFractionDigits: 1}).format(value)} ${unit}` : 'Ingen mätning';
    }
  }
  async history(start, end) {
    const entities = [this._config.temperature, this._config.humidity].filter(Boolean);
    const rows = await this._hass.callApi('GET', `history/period/${start.toISOString()}?end_time=${encodeURIComponent(end.toISOString())}&filter_entity_id=${encodeURIComponent(entities.join(','))}&no_attributes=1`);
    return entities.map(entity => historyPoints((rows.find(r => r[0]?.entity_id === entity) || []), +start, +end));
  }
  graphs(series, start, end) {
    return chart(series[0] || [], +start, +end, '#ffb74d', 'Temperatur (°C)')
      + (this._config.humidity ? chart(series[1] || [], +start, +end, '#4fc3f7', 'Luftfuktighet (%)') : '');
  }
  async loadPreview() {
    this._loading = true; this._last = Date.now();
    const start = new Date(Date.now() - 86400000), end = new Date();
    const target = this.shadowRoot.querySelector('.preview');
    try { target.innerHTML = this.graphs(await this.history(start, end), start, end); }
    catch { target.textContent = 'Historik kan inte hämtas just nu'; }
    finally { this._loading = false; }
  }
  async loadDate(day) {
    const request = ++this._request, target = this.shadowRoot.querySelector('.large');
    target.textContent = 'Hämtar historik…';
    try {
      const [start, end] = calendarRange(day, this.zone());
      const rows = await this.history(start, end);
      if (request !== this._request) return;
      target.innerHTML = this.graphs(rows, start, end);
      this.shadowRoot.querySelector('.range').textContent = `${day} · 00–24 (${this.zone()})`;
    } catch { if (request === this._request) target.textContent = 'Historik kan inte hämtas för det datumet'; }
  }
}

class LandetClipsCard extends HTMLElement {
  constructor() { super(); this.attachShadow({mode: 'open'}); this._last = 0; this._loading = false; this._blobs = []; this._key = null; }
  setConfig(config) {
    if (!/^[A-Za-z0-9_-]+$/.test(config.instance_id)) throw new Error('Invalid Frigate instance');
    this._config = config;
  }
  getCardSize() { return 6; }
  connectedCallback() {
    if (this._hass) this.load();
    this._timer = setInterval(() => { if (this._hass && !this._loading) this.load(); }, 60000);
  }
  set hass(hass) {
    this._hass = hass;
    if (!this.shadowRoot.firstChild) this.build();
    if (this.isConnected && Date.now() - this._last > 60000 && !this._loading) this.load();
  }
  disconnectedCallback() { clearInterval(this._timer); this.stopVideo(); this.releaseBlobs(); this._key = null; this._last = 0; }
  releaseBlobs() { this._blobs.forEach(URL.revokeObjectURL); this._blobs = []; }
  stopVideo() {
    const video = this.shadowRoot.querySelector('video');
    if (video) { video.pause(); video.removeAttribute('src'); video.load(); }
    this.shadowRoot.querySelector('dialog')?.close();
  }
  build() {
    this.shadowRoot.innerHTML = `<style>${styles}</style><ha-card><div class="toolbar"><h2>Senaste klipp</h2><button class="refresh">Uppdatera</button></div><p class="muted">De tio senaste inspelade händelserna · Tryck på en bild</p><p class="status">Hämtar klipp…</p><div class="grid"></div></ha-card><dialog aria-label="Inspelat klipp"><div class="toolbar"><h2 class="title"></h2><button class="close">Stäng</button></div><p class="player-status"></p><video controls playsinline preload="metadata"></video></dialog>`;
    this.shadowRoot.querySelector('.refresh').onclick = () => this.load();
    this.shadowRoot.querySelector('.close').onclick = () => this.stopVideo();
    const dialog = this.shadowRoot.querySelector('dialog');
    dialog.addEventListener('cancel', () => this.stopVideo());
    const video = dialog.querySelector('video');
    video.onerror = () => { dialog.querySelector('.player-status').textContent = 'Klippet går inte att spela just nu. Det kan ha tagits bort.'; };
  }
  label(event) {
    const name = this._config.cameras[event.camera] || event.camera;
    const date = new Intl.DateTimeFormat('sv-SE', {timeZone: this._hass.config.time_zone, dateStyle: 'short', timeStyle: 'short'}).format(new Date(event.start_time * 1000));
    return `${name} · ${date}`;
  }
  async load() {
    if (this._loading) return;
    this._loading = true; this._last = Date.now();
    const status = this.shadowRoot.querySelector('.status');
    try {
      const events = recentClips(await this._hass.callWS({type: 'frigate/events/get', instance_id: this._config.instance_id,
        cameras: Object.keys(this._config.cameras), has_clip: true, limit: 20}), Object.keys(this._config.cameras));
      if (!this.isConnected) return;
      status.textContent = events.length ? '' : 'Inga inspelade händelser finns ännu';
      const key = events.map(e => e.id).join(',');
      if (key === this._key) return;
      this._key = key; this.releaseBlobs();
      const grid = this.shadowRoot.querySelector('.grid'); grid.replaceChildren();
      for (const event of events) {
        const button = document.createElement('button'); button.className = 'clip';
        const image = document.createElement('img'); image.alt = this.label(event); image.loading = 'lazy';
        const label = document.createElement('span'); label.textContent = `▶ ${this.label(event)}`;
        button.append(image, label); button.onclick = () => this.play(event); grid.append(button);
        const path = `/api/frigate/${this._config.instance_id}/thumbnail/${encodeURIComponent(event.id)}`;
        try {
          const response = await this._hass.fetchWithAuth(path);
          if (!response.ok) continue;
          const blob = URL.createObjectURL(await response.blob());
          if (!this.isConnected || this._key !== key) { URL.revokeObjectURL(blob); continue; }
          this._blobs.push(blob); image.src = blob;
        } catch { /* The readable play button remains usable without its thumbnail. */ }
      }
    } catch { status.textContent = 'Klipp kan inte hämtas just nu. Tryck Uppdatera för att försöka igen.'; }
    finally { this._loading = false; }
  }
  async play(event) {
    const dialog = this.shadowRoot.querySelector('dialog'), video = dialog.querySelector('video');
    this.stopVideo(); dialog.querySelector('.title').textContent = this.label(event);
    dialog.querySelector('.player-status').textContent = 'Hämtar video…'; dialog.showModal();
    try {
      const path = `/api/frigate/${this._config.instance_id}/notifications/${encodeURIComponent(event.id)}/clip.mp4`;
      const signed = await this._hass.callWS({type: 'auth/sign_path', path, expires: 900});
      if (!dialog.open) return;
      video.src = safeMediaPath(signed.path, window.location.origin);
      video.muted = true; dialog.querySelector('.player-status').textContent = '';
      await video.play().catch(() => {});
    } catch { dialog.querySelector('.player-status').textContent = 'Videon kan inte öppnas just nu. Stäng och försök igen.'; }
  }
}

if (!customElements.get('landet-climate-card')) customElements.define('landet-climate-card', LandetClimateCard);
if (!customElements.get('landet-clips-card')) customElements.define('landet-clips-card', LandetClipsCard);
