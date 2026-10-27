#!/usr/bin/env python3
"""Loopback-only read-only integration proof. Not a production Access gateway."""
import argparse
from contextlib import closing
from datetime import date, datetime, time as dtime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import socket
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, urlencode, urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler
from zoneinfo import ZoneInfo

CAMERA = 'tplink_c200_1'
TEMPERATURE = 'sensor.third_reality_inc_3rths24bz_temperature'
HUMIDITY = 'sensor.third_reality_inc_3rths24bz_humidity'
CAMERAS = {'c200': {'entity': CAMERA, 'name': 'Kamera 1', 'model': 'Tapo C200'},
           'c320': {'entity': 'tplink_c320ws_1', 'name': 'Kamera 2', 'model': 'Tapo C320WS'}}
ROOMS = {
 'living': {'name': 'Kök', 'temperature': TEMPERATURE, 'humidity': HUMIDITY},
 'bedroom': {'name': 'Sovrum', 'temperature': 'sensor.sonoff_snzb_02dr2_temperature', 'humidity': 'sensor.sonoff_snzb_02dr2_humidity'},
 'nest': {'name': 'Örnnästet', 'temperature': 'sensor.sonoff_snzb_02dr2_temperature_2', 'humidity': 'sensor.sonoff_snzb_02dr2_humidity_2'},
 'outside': {'name': 'Utomhus', 'temperature': 'sensor.sonoff_snzb_02ld', 'humidity': None}}
ZONE = ZoneInfo('Europe/Stockholm')
CLIP_LIMIT = 9
MAX_JSON = 2_000_000

class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

class UpstreamError(Exception):
    pass


def number(value):
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (TypeError, ValueError):
        return None


def day_bounds(value, today=None):
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
        raise ValueError('Invalid date')
    selected = date.fromisoformat(value)
    today = today or datetime.now(ZONE).date()
    if not today - timedelta(days=9) <= selected <= today:
        raise ValueError('Date outside ten-day proof window')
    start = datetime.combine(selected, dtime(), ZONE)
    end = datetime.combine(selected + timedelta(days=1), dtime(), ZONE)
    return start, end


def validate_origin(value):
    parsed = urlsplit(value)
    if parsed.scheme != 'http' or parsed.path or parsed.query or parsed.fragment or parsed.username:
        raise ValueError('Expected private HTTP origin')
    if not ipaddress.ip_address(parsed.hostname).is_private:
        raise ValueError('Expected private IP address')
    return value


class Sources:
    def __init__(self, ha, frigate, token):
        self.ha, self.frigate, self.token = validate_origin(ha), validate_origin(frigate), token
        self.relay = os.environ.get('LANDET_RELAY_ORIGIN')
        if self.relay and self.relay not in ('http://127.0.0.1:1986', 'http://127.0.0.1:1987'):
            raise ValueError('Unexpected relay origin')
        self.opener = build_opener(NoRedirect())
        self.clip_lock = threading.Lock()
        self.clip_cache = (0, None)
        self.issued = {}
        self.live_slots = threading.BoundedSemaphore(2)
        self.video_slots = threading.BoundedSemaphore(1)

    def open(self, source, path, headers=None):
        base = self.ha if source == 'ha' else self.relay if source == 'relay' else self.frigate
        h = dict(headers or {})
        if source == 'ha':
            h['Authorization'] = 'Bearer ' + self.token
        try:
            return self.opener.open(Request(base + path, headers=h), timeout=10)
        except (HTTPError, URLError, TimeoutError, OSError) as exc:
            # Never send upstream errors/URLs/headers to the browser or log.
            raise UpstreamError('Upstream unavailable') from exc

    def json(self, source, path):
        with closing(self.open(source, path)) as response:
            raw = response.read(MAX_JSON + 1)
            if len(raw) > MAX_JSON:
                raise UpstreamError('Response too large')
            try:
                return json.loads(raw)
            except (ValueError, UnicodeError) as exc:
                raise UpstreamError('Invalid upstream data') from exc

    def climate(self):
        result = []
        for key, room in ROOMS.items():
            values = {'id': key, 'name': room['name']}
            for kind in ['temperature', 'humidity']:
                if room[kind] is None:
                    values[kind] = None
                    continue
                try:
                    state = self.json('ha', '/api/states/' + room[kind])
                    values[kind] = {'value': number(state.get('state')), 'updated': state.get('last_updated')}
                except UpstreamError:
                    values[kind] = {'value': None, 'updated': None}
            result.append(values)
        return {'rooms': result, 'retrieved': datetime.now(timezone.utc).isoformat(),
                **{k: v for k, v in result[0].items() if k != 'id'}}

    def history(self, value, room_id='living'):
        room = ROOMS[room_id]
        if value == '24h':
            end = datetime.now(timezone.utc)
            start = end - timedelta(hours=24)
        else:
            start, end = day_bounds(value)
        entities = [room[k] for k in ['temperature', 'humidity'] if room[k]]
        query = urlencode({'filter_entity_id': ','.join(entities),
                           'end_time': end.isoformat(), 'minimal_response': '1', 'no_attributes': '1'})
        rows = self.json('ha', '/api/history/period/' + quote(start.isoformat(), safe='') + '?' + query)
        result = {'date': value, 'start': start.isoformat(), 'end': end.isoformat(),
                  'temperature': [], 'humidity': []}
        for series in rows:
            if not series:
                continue
            entity = series[0].get('entity_id')
            key = 'temperature' if entity == room['temperature'] else 'humidity' if room['humidity'] and entity == room['humidity'] else None
            if key is None:
                continue
            # Preserve unavailable states as explicit gaps, not invented values.
            for row in series:
                stamp = row.get('last_changed', row.get('last_updated'))
                if not isinstance(stamp, str):
                    continue
                try:
                    instant = datetime.fromisoformat(stamp)
                    if not start <= instant <= end:
                        continue
                except (ValueError, TypeError):
                    continue
                result[key].append({'time': instant.isoformat(), 'value': number(row.get('state'))})
        return result

    def clips(self):
        with self.clip_lock:
            now = time.monotonic()
            if now - self.clip_cache[0] < 20:
                return self.clip_cache[1]
            events = []
            for cam in CAMERAS.values():
                query = urlencode({'camera': cam['entity'], 'has_clip': 1, 'in_progress': 0, 'limit': CLIP_LIMIT})
                events.extend(self.json('frigate', '/api/events?' + query))
            valid = [e for e in events if e.get('camera') in {c['entity'] for c in CAMERAS.values()} and e.get('has_clip')
                     and e.get('end_time') is not None and re.fullmatch(r'[a-zA-Z0-9_.-]{1,90}', str(e.get('id', '')))
                     and number(e.get('start_time')) is not None and number(e.get('end_time')) is not None]
            valid.sort(key=lambda e: float(e['start_time']), reverse=True)
            result, seen = [], set()
            self.issued = {key: expires for key, expires in self.issued.items() if expires > now}
            for e in valid:
                if e['id'] in seen:
                    continue
                seen.add(e['id'])
                cam_id = next(k for k, c in CAMERAS.items() if c['entity'] == e['camera'])
                result.append({'id': e['id'], 'camera': cam_id, 'started': float(e['start_time']),
                               'ended': float(e['end_time']), 'duration': max(0, float(e['end_time']) - float(e['start_time']))})
                self.issued[e['id']] = now + 900
                if len(result) == CLIP_LIMIT:
                    break
            while len(self.issued) > 48:
                self.issued.pop(next(iter(self.issued)))
            self.clip_cache = (now, result)
            return result

    def clip(self):
        result = self.clips()
        return result[0] if result else None

    def authorize_clip(self, event):
        # Only recently server-issued clip IDs are exposed, including active players.
        with self.clip_lock:
            if self.issued.get(event, 0) <= time.monotonic():
                return False
        # Re-check camera ownership and retention; reject stale/missing events.
        row = self.json('frigate', '/api/events/' + event)
        return row.get('camera') in {c['entity'] for c in CAMERAS.values()} and row.get('has_clip') and row.get('end_time') is not None


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    def __init__(self, address, sources):
        super().__init__(address, Handler)
        self.sources = sources
        self.access = None
        self.public_origin = None
        mode = os.environ.get('LANDET_MODE', 'local')
        if mode not in ('local', 'access'):
            raise ValueError('Invalid viewer mode')
        if mode == 'access':
            from access import AccessGuard
            self.access = AccessGuard(os.environ['LANDET_ACCESS_ISSUER'], os.environ['LANDET_ACCESS_AUD'], os.environ['LANDET_OWNER_EMAIL'])
            self.public_origin = 'https://landet.ostmarken.se'

        root = Path(__file__).parent / 'static'
        self.assets = {'/': ((root / 'index.html').read_bytes(), 'text/html; charset=utf-8'),
                       '/proof.js': ((root / 'proof.js').read_bytes(), 'text/javascript; charset=utf-8'),
                       '/proof.css': ((root / 'proof.css').read_bytes(), 'text/css; charset=utf-8'),
                       '/vendor/hls.light.min.js': ((root / 'vendor/hls.light.min.js').read_bytes(), 'text/javascript; charset=utf-8')}
        self.slots = threading.BoundedSemaphore(12)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        pass  # Avoid logging upstream paths or private state on disconnect.


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, *args):
        pass  # No request logs containing sensor or media identifiers.

    def headers_common(self):
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Cross-Origin-Resource-Policy', 'same-origin')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; media-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
        self.send_header('Connection', 'close')
        self.close_connection = True

    def reply(self, code, body, content_type='application/json'):
        raw = json.dumps(body, allow_nan=False).encode() if isinstance(body, (dict, list)) else body
        self.send_response(code)
        self.headers_common()
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(raw)

    def allowed(self):
        port = self.server.server_port
        host = self.headers.get('Host', '')
        origin = self.headers.get('Origin')
        return (host in (f'127.0.0.1:{port}', f'localhost:{port}')
                and (not origin or origin in (f'http://127.0.0.1:{port}', f'http://localhost:{port}', self.server.public_origin))
                and (self.headers.get('Sec-Fetch-Site', 'none') in ('same-origin', 'none')
                     or (self.server.access and self.headers.get('Sec-Fetch-Mode') == 'navigate'
                         and self.headers.get('Sec-Fetch-Dest') == 'document')))

    def do_POST(self):
        self.reply(405, {'error': 'Read-only proof'})
    do_PUT = do_PATCH = do_DELETE = do_OPTIONS = do_POST

    def do_HEAD(self):
        self.reply(405, {'error': 'Use GET'})

    def do_GET(self):
        try:
            if not self.allowed():
                return self.reply(403, {'error': 'Local origin required'})
            if self.path == '/healthz':
                return self.reply(200, {'status': 'ready', 'mode': 'access' if self.server.access else 'local'})
            if self.server.access and not self.server.access.allows(self.headers.get('Cf-Access-Jwt-Assertion')):
                return self.reply(401, {'error': 'Authentication required'})
            parsed = urlsplit(self.path)
            if '%' in parsed.path or '//' in parsed.path or '\\' in parsed.path:
                return self.reply(400, {'error': 'Invalid path'})
            query = parse_qs(parsed.query, keep_blank_values=True)
            path = parsed.path
            if path == '/api/history':
                if set(query) not in ({'date'}, {'date', 'room'}) or len(query.get('date', [])) != 1 or len(query.get('room', ['living'])) != 1 or query.get('room', ['living'])[0] not in ROOMS:
                    return self.reply(400, {'error': 'One date required'})
                return self.reply(200, self.server.sources.history(query['date'][0], query.get('room', ['living'])[0]))
            if query:
                return self.reply(400, {'error': 'Query not allowed'})
            if path in self.server.assets:
                return self.reply(200, *self.server.assets[path])
            if path == '/api/info':
                today = datetime.now(ZONE).date()
                return self.reply(200, {'cameras': [{'id': k, 'name': c['name'], 'model': c['model']} for k, c in CAMERAS.items()],
                                       'rooms': [{'id': k, 'name': r['name'], 'humidity': bool(r['humidity'])} for k, r in ROOMS.items()],
                                       'today': today.isoformat(), 'earliest': (today - timedelta(days=9)).isoformat(),
                                       'timezone': 'Europe/Stockholm', 'live_format': 'mp4' if self.server.sources.relay else 'mjpeg'})
            if path == '/api/climate':
                return self.reply(200, self.server.sources.climate())
            if path == '/api/clips':
                return self.reply(200, {'clips': [{k: v for k, v in clip.items() if k != 'id'} |
                    {'id': clip['id'], 'video': '/api/vod/' + clip['id'] + '/index.m3u8',
                     'thumbnail': '/api/thumbnail/' + clip['id'] + '.jpg'} for clip in self.server.sources.clips()]})
            thumb = re.fullmatch(r'/api/thumbnail/([a-zA-Z0-9_.-]{1,90})\.jpg', path)
            if thumb:
                if not self.server.sources.authorize_clip(thumb[1]):
                    return self.reply(404, {'error': 'Clip unavailable'})
                return self.image('/api/events/' + thumb[1] + '/thumbnail.jpg')
            cam = re.fullmatch(r'/api/cameras/(c200|c320)/(live\.mp4|live|thumbnail\.jpg)', path)
            if cam:
                if cam[2] == 'thumbnail.jpg':
                    return self.image('/api/' + CAMERAS[cam[1]]['entity'] + '/latest.jpg?h=180')
                if cam[2] == 'live':
                    return self.live(cam[1])
                if not self.server.sources.relay:
                    return self.reply(404, {'error': 'HQ relay not running'})
                return self.live_mp4(cam[1])
            if path == '/api/clip':
                clip = self.server.sources.clip()
                if clip:
                    clip = {k: v for k, v in clip.items() if k != 'id'} | {'video': '/api/vod/' + clip['id'] + '/index.m3u8'}
                return self.reply(200, {'clip': clip})
            if path == '/api/live.mp4':
                if not self.server.sources.relay:
                    return self.reply(404, {'error': 'HQ relay not running'})
                return self.live_mp4()
            vod = re.fullmatch(r'/api/vod/([a-zA-Z0-9_.-]{1,90})/([a-zA-Z0-9_-]+\.(?:m3u8|m4s|mp4))', path)
            if vod:
                if not self.server.sources.authorize_clip(vod[1]):
                    return self.reply(404, {'error': 'Clip unavailable'})
                return self.vod(vod[1], vod[2])
            if path == '/api/live':
                return self.live()
            match = re.fullmatch(r'/api/clip/([a-zA-Z0-9_.-]{1,90})\.mp4', path)
            if match:
                if not self.server.sources.authorize_clip(match[1]):
                    return self.reply(404, {'error': 'Clip unavailable'})
                if not self.server.sources.video_slots.acquire(blocking=False):
                    return self.reply(429, {'error': 'One pilot clip transfer already active'})
                try:
                    return self.video('/api/events/' + match[1] + '/clip.mp4')
                finally:
                    self.server.sources.video_slots.release()
            return self.reply(404, {'error': 'Unknown resource'})
        except ValueError:
            self.reply(400, {'error': 'Invalid request or date outside ten-day window'})
        except UpstreamError:
            self.reply(502, {'error': 'Source unavailable; retry shortly'})
        except (BrokenPipeError, ConnectionResetError, TimeoutError, socket.timeout):
            pass
        except Exception:
            # No raw upstream responses, traceback, URLs or credentials.
            if not self.wfile.closed:
                try:
                    self.reply(502, {'error': 'Source unavailable'})
                except OSError:
                    pass

    def vod(self, event, filename):
        allowed = r'(?:index(?:-v1(?:-a1)?)?|master)\.m3u8|init-v1(?:-a1)?\.mp4|seg-[0-9]+-v1(?:-a1)?\.m4s'
        if not re.fullmatch(allowed, filename):
            return self.reply(404, {'error': 'Unknown media resource'})
        with closing(self.server.sources.open('frigate', '/vod/event/' + event + '/' + filename)) as upstream:
            if filename.endswith('.m3u8'):
                raw = upstream.read(MAX_JSON + 1)
                if len(raw) > MAX_JSON:
                    raise UpstreamError('Playlist too large')
                text = raw.decode()
                if not text.startswith('#EXTM3U'):
                    raise UpstreamError('Invalid playlist')
                # Only simple sibling media names; no origins, URLs, queries or traversal.
                for line in text.splitlines():
                    refs = re.findall(r'URI="([^"]+)"', line) if line.startswith('#') else ([line] if line else [])
                    if any(not re.fullmatch(allowed, ref) for ref in refs):
                        raise UpstreamError('Unexpected playlist reference')
                return self.reply(200, text.encode(), 'application/vnd.apple.mpegurl')
            raw = upstream.read(16 * 1024 * 1024 + 1)
            if len(raw) > 16 * 1024 * 1024:
                raise UpstreamError('Segment too large')
            return self.reply(200, raw, 'video/mp4')

    def image(self, path):
        with closing(self.server.sources.open('frigate', path)) as upstream:
            raw = upstream.read(2 * 1024 * 1024 + 1)
            if len(raw) > 2 * 1024 * 1024 or not raw.startswith(b'\xff\xd8'):
                raise UpstreamError('Invalid image')
            return self.reply(200, raw, 'image/jpeg')

    def live_mp4(self, camera='c200'):
        if not self.server.sources.live_slots.acquire(blocking=False):
            return self.reply(429, {'error': 'Live viewer limit'})
        try:
            with closing(self.server.sources.open('relay', '/api/stream.mp4?' + urlencode({'src': camera, 'video': 'h264', 'audio': 'aac'}))) as upstream:
                content_type = upstream.headers.get('Content-Type', '')
                if not content_type.startswith('video/mp4'):
                    raise UpstreamError('Invalid media')
                self.send_response(200)
                self.headers_common()
                self.send_header('Content-Type', content_type)
                self.end_headers()
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    chunk = upstream.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        except (OSError, TimeoutError):
            pass
        finally:
            self.server.sources.live_slots.release()

    def live(self, camera='c200'):
        if not self.server.sources.live_slots.acquire(blocking=False):
            return self.reply(429, {'error': 'Two live viewers already active'})
        try:
            with closing(self.server.sources.open('frigate', '/api/' + CAMERAS[camera]['entity'] + '?fps=5&h=360')) as upstream:
                content_type = upstream.headers.get('Content-Type', '')
                if not content_type.startswith('multipart/x-mixed-replace;'):
                    raise UpstreamError('Invalid media')
                self.send_response(200)
                self.headers_common()
                self.send_header('Content-Type', content_type)
                self.end_headers()
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    chunk = upstream.read1(16384)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        except (OSError, TimeoutError):
            pass
        finally:
            self.server.sources.live_slots.release()

    def video(self, path):
        headers = {}
        value = self.headers.get('Range')
        if value:
            if not re.fullmatch(r'bytes=(?:\d+-\d*|-\d+)', value) or len(value) > 80:
                return self.reply(416, {'error': 'One byte range required'})
            headers['Range'] = value
        with closing(self.server.sources.open('frigate', path, headers)) as upstream:
            if upstream.status not in (200, 206) or not upstream.headers.get('Content-Type', '').startswith('video/mp4'):
                raise UpstreamError('Invalid media')
            self.send_response(upstream.status)
            self.headers_common()
            self.send_header('Content-Type', 'video/mp4')
            for key in ['Content-Length', 'Content-Range', 'Accept-Ranges']:
                if upstream.headers.get(key):
                    self.send_header(key, upstream.headers[key])
            self.end_headers()
            # Stop reading promptly if the browser disconnects. No disk copy.
            total = 0
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                chunk = upstream.read1(65536)
                if not chunk:
                    break
                total += len(chunk)
                if total > 64 * 1024 * 1024:
                    break
                self.wfile.write(chunk)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--require-access', action='store_true', help='Require Access even if environment mode is missing or local')
    parser.add_argument('--check', action='store_true', help='Bounded read-only upstream probe; no server')
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error('Port must be 1024..65535')
    if args.require_access:
        os.environ['LANDET_MODE'] = 'access'
    try:
        sources = Sources(os.environ['LANDET_HA_ORIGIN'], os.environ['LANDET_FRIGATE_ORIGIN'], os.environ['HA_TOKEN'])
        if not sources.token:
            raise ValueError('Missing token')
        if args.check:
            climate = sources.climate()
            if len(climate['rooms']) != 4:
                raise UpstreamError('Room configuration unavailable')
            for room in climate['rooms']:
                ok = all(room[k] is None or room[k]['value'] is not None for k in ['temperature','humidity'])
                print(room['name'], 'readings available:', ok)
                history = sources.history('24h', room['id'])
                print(room['name'], 'history points:', len(history['temperature']), len(history['humidity']))
                if not ok or not history['temperature'] or (ROOMS[room['id']]['humidity'] and not history['humidity']):
                    raise UpstreamError('Sensor or history unavailable')
            clips = sources.clips()
            print('Completed retained clips:', len(clips))
            for key, cam in CAMERAS.items():
                with closing(sources.open('frigate', '/api/' + cam['entity'] + '?fps=5&h=360')) as stream:
                    frame_ok = b'\xff\xd8' in stream.read(8192)
                    print(cam['model'], 'live JPEG frame:', frame_ok)
                    if not frame_ok:
                        raise UpstreamError('Live frame unavailable')
            if not clips:
                print('No retained clips currently available (valid empty state).')
            return
        with Server(('127.0.0.1', args.port), sources) as server:
            print(f'Local proof: http://127.0.0.1:{args.port} (Ctrl+C stops; no installed service)', flush=True)
            server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    except (KeyError, ValueError, UpstreamError, OSError):
        parser.exit(1, 'Proof failed: check private configuration, upstream health, or occupied port.\n')

if __name__ == '__main__':
    main()
