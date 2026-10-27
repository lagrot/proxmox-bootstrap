import {test} from 'node:test';
import assert from 'node:assert/strict';
globalThis.HTMLElement = class {};
globalThis.customElements = {get: () => false, define: () => {}};
const {calendarRange, historyPoints, recentClips, safeMediaPath} = await import('../frontend/landet-cards.js');

test('calendar dates use the site timezone, including both seasonal transitions', () => {
  const normal = calendarRange('2026-10-26', 'Europe/Stockholm');
  assert.equal(normal[0].toISOString(), '2026-10-25T23:00:00.000Z');
  assert.equal(+normal[1] - +normal[0], 24 * 3600000);
  for (const [day, hours] of [['2026-03-29', 23], ['2026-10-25', 25]]) {
    const [start, end] = calendarRange(day, 'Europe/Stockholm');
    assert.equal(+end - +start, hours * 3600000);
  }
  assert.throws(() => calendarRange('2026-02-30', 'Europe/Stockholm'));
});

test('unavailable measurements are not turned into zeroes', () => {
  const start = Date.parse('2026-10-26T00:00:00Z'), end = start + 86400000;
  const values = historyPoints([
    {state: 'unavailable', last_changed: '2026-10-26T01:00:00Z'},
    {state: '', last_changed: '2026-10-26T02:00:00Z'},
    {state: null, last_changed: '2026-10-26T03:00:00Z'},
    {state: '10.9', last_changed: '2026-10-26T04:00:00Z'},
    {state: '-2.3', last_changed: '2026-10-26T05:00:00Z'},
  ], start, end);
  assert.deepEqual(values.map(p => p.value), [10.9, -2.3]);
});

test('only ten most recent completed clips from configured cameras are offered', () => {
  const events = Array.from({length: 20}, (_, i) => ({id: `${1000 + i}-abc`, camera: 'one', has_clip: true, start_time: i, end_time: i + 1}));
  events.push({id: '3000-x', camera: 'other', has_clip: true, start_time: 200, end_time: 201});
  events.push({id: '3001-x', camera: 'one', has_clip: true, start_time: 201, end_time: null});
  events.push({id: '../../escape', camera: 'one', has_clip: true, start_time: 203, end_time: 204});
  const clips = recentClips(JSON.stringify(events), ['one', 'two']);
  assert.equal(clips.length, 10);
  assert.equal(clips[0].start_time, 19);
  assert.equal(clips[9].start_time, 10);
  assert.deepEqual(recentClips([], ['one']), []);
});

test('media cannot leave the protected HA origin or Frigate proxy', () => {
  const origin = 'https://ha.ostmarken.se';
  assert.equal(safeMediaPath('/api/frigate/frigate/notifications/1000-abc/clip.mp4?authSig=test', origin), '/api/frigate/frigate/notifications/1000-abc/clip.mp4?authSig=test');
  for (const url of ['http://192.168.8.104:5000/clip.mp4', 'https://example.com/video', '//example.com/api/frigate/x', '/api/config', '/api/frigate/../../config']) {
    assert.throws(() => safeMediaPath(url, origin));
  }
});
