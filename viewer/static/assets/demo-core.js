(function (root) {
  "use strict";
  const format = (value, digits = 1) => new Intl.NumberFormat("sv-SE", {maximumFractionDigits: digits}).format(value);
  const escape = value => String(value).replace(/[&<>"']/g, char => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[char]));
  function validDate(value) {
    return /^\d{4}-\d{2}-\d{2}$/.test(value) && !Number.isNaN(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value;
  }
  function history(room, date) {
    if (!validDate(date)) throw new Error("Ogiltigt datum");
    const seed = [...room.id + date].reduce((sum, char) => (sum * 31 + char.charCodeAt(0)) % 997, 7);
    const phase = seed / 99;
    const temperatures = [], humidity = [];
    for (let index = 0; index <= 96; index++) {
      const hour = index / 4;
      const wave = Math.sin(hour / 3 + phase) * .42 + Math.cos(hour / 1.8 + phase) * .11;
      temperatures.push({hour, value: room.temperature + wave});
      if (room.humidity != null) humidity.push({hour, value: room.humidity + Math.sin(hour / 4 + phase) * 2.2 + Math.cos(hour / 2) * .4});
    }
    return {temperatures, humidity};
  }
  function coordinates(points, width = 600, height = 90, pad = 5) {
    if (!points.length) return {line: "", area: "", low: null, high: null};
    let low = Math.min(...points.map(point => point.value)), high = Math.max(...points.map(point => point.value));
    const extra = Math.max((high - low) * .22, .15); low -= extra; high += extra;
    const pairs = points.map(point => [pad + point.hour / 24 * (width - pad * 2), height - pad - (point.value - low) / (high - low) * (height - pad * 2)]);
    const line = pairs.map(([x, y]) => `${x.toFixed(2)},${y.toFixed(2)}`).join(" ");
    return {line, area: `${pad},${height} ${line} ${width - pad},${height}`, low, high};
  }
  function clips(cameras, date) {
    if (!validDate(date) || cameras.length !== 2) throw new Error("Ogiltiga exempeldata");
    const start = Date.parse(date + "T14:42:00+01:00");
    const offsets = [0, 58, 109, 162, 213, 269, 321, 379, 451, 510, 620, 729];
    const durations = [24, 36, 18, 27, 32, 21, 42, 16, 28, 34, 19, 25];
    return offsets.map((minutes, index) => ({id: `sample-${index + 1}`, camera: cameras[index % 2].id,
      name: cameras[index % 2].name, started: start - minutes * 60000, duration: durations[index]}));
  }
  function duration(seconds) {
    const rounded = Math.max(0, Math.floor(seconds));
    return `${String(Math.floor(rounded / 60)).padStart(2,"0")}:${String(rounded % 60).padStart(2,"0")}`;
  }
  root.LandetDemoCore = Object.freeze({format, escape, validDate, history, coordinates, clips, duration});
})(typeof window === "undefined" ? globalThis : window);
