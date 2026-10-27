(function () {
  "use strict";
  const Core = window.LandetDemoCore;
  const demo = JSON.parse(document.getElementById("demo-config").textContent);
  const settings = demo.settings, cameras = settings.cameras, rooms = settings.locations;
  const $ = selector => document.querySelector(selector);
  const $$ = selector => [...document.querySelectorAll(selector)];
  const media = $("#media-dialog"), historyDialog = $("#history-dialog");
  let activeRoom = null, activeClip = null, playback = 0, playbackTimer = null, lastInvoker = null, wasFullscreen = false;
  const icon = name => `<svg class="icon" aria-hidden="true"><use href="#i-${name}"/></svg>`;

  function showView(view, changeHash = true) {
    const selected = view === "temperatur" ? "temperatur" : "kameror";
    for (const button of $$(".nav-button")) {
      const active = button.dataset.view === selected;
      button.classList.toggle("active", active);
      if (active) button.setAttribute("aria-current", "page"); else button.removeAttribute("aria-current");
    }
    $("#view-kameror").hidden = selected !== "kameror";
    $("#view-temperatur").hidden = selected !== "temperatur";
    if (changeHash && window.location.hash !== `#${selected}`) window.location.hash = selected;
    document.title = `Landet · ${selected === "kameror" ? "Kameror" : "Temperatur"}`;
  }
  $$(".nav-button").forEach(button => button.addEventListener("click", () => showView(button.dataset.view)));
  window.addEventListener("hashchange", () => showView(window.location.hash.slice(1), false));
  showView(window.location.hash.slice(1), false);

  function plotSVG(points, key, color, options = {}) {
    const height = options.large ? 170 : 86;
    const data = Core.coordinates(points, 600, height, options.large ? 8 : 3);
    const id = `gradient-${key}`;
    const grid = options.large ? [1,2,3].map(n => `<line x1="0" x2="600" y1="${height*n/4}" y2="${height*n/4}" stroke="#e7e8df" stroke-width="1"/>`).join("") : "";
    return `<svg viewBox="0 0 600 ${height}" preserveAspectRatio="none" aria-hidden="true"><defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="${color}" stop-opacity=".16"/><stop offset="100%" stop-color="${color}" stop-opacity="0"/></linearGradient></defs>${grid}<polygon fill="url(#${id})" points="${data.area}"/><polyline fill="none" stroke="${color}" stroke-width="${options.large ? 2.3 : 1.8}" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke" points="${data.line}"/></svg>`;
  }

  for (const room of rooms) {
    const element = $(`[data-room="${room.id}"]`);
    element.querySelector(".temperature-value").innerHTML = `${Core.format(room.temperature)}<span>°C</span>`;
    const data = Core.history(room, settings.demo_date);
    const preview = element.querySelector(".mini-chart");
    preview.innerHTML = plotSVG(data.temperatures, `${room.id}-preview`, "#a87b49");
    if (data.humidity.length) {
      const humidityLine = Core.coordinates(data.humidity, 600, 86, 3);
      preview.querySelector("svg").insertAdjacentHTML("beforeend", `<polyline fill="none" stroke="#7e9c9c" stroke-width="1.6" stroke-dasharray="5 5" stroke-linecap="round" vector-effect="non-scaling-stroke" points="${humidityLine.line}"/>`);
    }
  }

  function historyPlot(points, label, unit, color, key) {
    const minimum = Math.min(...points.map(p => p.value)), maximum = Math.max(...points.map(p => p.value));
    return `<section class="history-plot"><div class="plot-heading"><span>${Core.escape(label)}</span><strong>${Core.format(minimum)}–${Core.format(maximum)} <span>${unit}</span></strong></div>${plotSVG(points, key, color, {large:true})}<div class="plot-hours"><span>00</span><span>06</span><span>12</span><span>18</span><span>24</span></div></section>`;
  }
  function drawHistory() {
    if (!activeRoom) return;
    const date = $("#history-date").value;
    if (!Core.validDate(date) || date > settings.demo_date) {
      $("#history-chart").textContent = "Välj ett giltigt datum fram till exempeldata-datumet.";
      return;
    }
    const data = Core.history(activeRoom, date);
    $("#history-chart").innerHTML = historyPlot(data.temperatures, "Temperatur", "°C", "#a87b49", "history-temperature")
      + (data.humidity.length ? historyPlot(data.humidity, "Luftfuktighet", "%", "#6c9293", "history-humidity") : "");
  }
  $$("[data-history]").forEach(button => button.addEventListener("click", () => {
    activeRoom = rooms.find(room => room.id === button.dataset.history);
    $("#history-title").textContent = activeRoom.name;
    $("#history-date").value = settings.demo_date;
    drawHistory(); historyDialog.showModal();
  }));
  $("#history-date").addEventListener("change", drawHistory);

  const clips = new URLSearchParams(window.location.search).get("demo") === "empty" ? [] : Core.clips(cameras, settings.demo_date);
  const dateFormat = new Intl.DateTimeFormat("sv-SE", {timeZone: settings.site_timezone, month:"numeric", day:"numeric", hour:"2-digit", minute:"2-digit"});
  const grid = $("#clips-grid");
  for (const clip of clips) {
    const button = document.createElement("button"); button.className = "clip-card"; button.dataset.clip = clip.id;
    button.setAttribute("aria-label", `Öppna exempelklipp från ${clip.name}, ${dateFormat.format(clip.started)}`);
    button.innerHTML = `<div class="clip-image"><img src="${Core.escape(demo.images[clip.camera])}" alt="" loading="lazy" width="1600" height="900"><span class="clip-play">${icon("play")}</span><span class="clip-duration">${Core.duration(clip.duration)}</span></div><div class="clip-description"><strong>${Core.escape(clip.name)}</strong><time datetime="${new Date(clip.started).toISOString()}">${Core.escape(dateFormat.format(clip.started))}</time></div>`;
    button.addEventListener("click", () => openMedia(clip.camera, button, clip)); grid.append(button);
  }
  if (!clips.length) {
    grid.innerHTML = '<p class="empty-message">Här visas inspelningar när de finns. Du provar ett exempel utan klipp.</p>';
    $(".count-label").textContent = "Inga exempelklipp";
  }

  function updatePlayback() {
    if (!activeClip) return;
    $("#player-time").textContent = `${Core.duration(playback)} / ${Core.duration(activeClip.duration)}`;
    $("#player-seek").value = playback;
  }
  function stopPlayback() {
    clearInterval(playbackTimer); playbackTimer = null;
    $("#play-toggle").innerHTML = `${icon("play")}<span>Spela</span>`;
    $("#play-toggle").setAttribute("aria-label", "Starta simulerad uppspelning");
  }
  function play() {
    if (!activeClip) return;
    if (playbackTimer) { stopPlayback(); return; }
    if (playback >= activeClip.duration) playback = 0;
    $("#play-toggle").innerHTML = `${icon("pause")}<span>Pausa</span>`;
    $("#play-toggle").setAttribute("aria-label", "Pausa simulerad uppspelning");
    playbackTimer = setInterval(() => {
      playback = Math.min(playback + .2, activeClip.duration); updatePlayback();
      if (playback >= activeClip.duration) stopPlayback();
    }, 200);
  }
  function openMedia(cameraId, invoker, clip = null) {
    stopPlayback(); lastInvoker = invoker; activeClip = clip; playback = 0;
    const camera = cameras.find(item => item.id === cameraId);
    $("#media-title").textContent = camera.name;
    $("#media-kind").textContent = clip ? "EXEMPELKLIPP" : "EXEMPELBILD";
    $("#media-image").src = demo.images[camera.id];
    $("#media-image").alt = `Påhittad exempelbild av ${camera.name.toLowerCase()}`;
    $("#demo-player").hidden = !clip;
    if (clip) { $("#player-seek").max = clip.duration; updatePlayback(); }
    media.showModal();
  }
  async function closeMedia() {
    stopPlayback(); activeClip = null;
    if (document.fullscreenElement) await document.exitFullscreen().catch(() => {});
    if (media.open) media.close();
    lastInvoker?.focus({preventScroll:true});
  }
  $$("[data-camera]").forEach(button => button.addEventListener("click", () => openMedia(button.dataset.camera, button)));
  $("#native-fullscreen").addEventListener("click", async () => {
    const shell = media.querySelector(".viewer-shell");
    if (document.fullscreenElement) await document.exitFullscreen().catch(() => {});
    else if (shell.requestFullscreen) await shell.requestFullscreen().catch(() => {});
  });
  document.addEventListener("fullscreenchange", () => {
    const entered = !!document.fullscreenElement;
    if (wasFullscreen && !entered && media.open) closeMedia();
    wasFullscreen = entered;
  });
  $("#play-toggle").addEventListener("click", play);
  $("#player-seek").addEventListener("input", event => { playback = Number(event.target.value); updatePlayback(); });
  $$("[data-close]").forEach(button => button.addEventListener("click", () => {
    if (button.dataset.close === "media-dialog") closeMedia(); else historyDialog.close();
  }));
  media.addEventListener("cancel", event => { event.preventDefault(); closeMedia(); });
  media.addEventListener("close", stopPlayback);
  document.addEventListener("visibilitychange", () => { if (document.hidden) stopPlayback(); });
})();
