"""Reversible, owner-preview-only Home Assistant camera dashboard."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import urllib.request
from urllib.parse import urlparse

PATH = 'landet-view'
VERSION = '15.0.0'
DIGEST = 'b54c24054c27980faeace330bbf019f3b03e54acfda190573a26026cddbf6cf1'
ASSET = f'https://github.com/NemesisRE/kiosk-mode/releases/download/v{VERSION}/kiosk-mode.js'
FILE = Path(f'/config/www/proxmox-bootstrap/kiosk-mode-v{VERSION}.js')
URL = f'/local/proxmox-bootstrap/kiosk-mode-v{VERSION}.js'
STATE = Path('/config/.proxmox-bootstrap/landet-dashboard.json')
UI_DATA = base64.b64decode(os.environ.get('LANDET_UI_B64', ''))
UI_DIGEST = hashlib.sha256(UI_DATA).hexdigest()
UI_FILE = FILE.parent / f'landet-cards-{UI_DIGEST[:12]}.js'
UI_URL = '/local/proxmox-bootstrap/' + UI_FILE.name


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def discover_temperatures(api, states):
    labels = {'Living Room': 'Vardagsrum', 'Bedroom': 'Sovrum',
              'Eagles Nest': 'Örnnästet', 'Outside': 'Utomhus'}
    found = []
    for path, location in [('climate-dashboard', 'Inomhus'), ('outdoor-climate', 'Utomhus')]:
        source = api.request('lovelace/config', url_path=path)
        for view in source.get('views', []):
            for section in view.get('sections', []):
                nodes = list(walk(section))
                sensors = {n['entity'] for n in nodes if n.get('entity') in states
                           and states[n['entity']].get('attributes', {}).get('device_class') == 'temperature'}
                if not sensors:
                    continue
                if len(sensors) != 1:
                    raise RuntimeError('Ambiguous thermometer section in existing climate dashboard')
                heading = next((n['heading'] for n in nodes if n.get('type') == 'heading'), None)
                if not heading:
                    raise RuntimeError('Thermometer location label is missing')
                humidity = {n['entity'] for n in nodes if n.get('entity') in states
                            and states[n['entity']].get('attributes', {}).get('device_class') == 'humidity'}
                if location == 'Inomhus' and len(humidity) != 1:
                    raise RuntimeError('Expected one humidity sensor for each indoor location')
                found.append({'entity': sensors.pop(), 'name': labels.get(heading, heading), 'location': location,
                              'humidity': humidity.pop() if humidity else None})
    if len(found) != 4 or len({x['entity'] for x in found}) != 4 or sum(x['location'] == 'Inomhus' for x in found) != 3:
        raise RuntimeError('Expected three indoor thermometers and one outdoor thermometer')
    return found


def navigation(active):
    buttons = []
    for name, path, icon in [('Kameror', 'live', 'mdi:cctv'), ('Temperatur', 'temperature', 'mdi:thermometer')]:
        buttons.append({'type': 'button', 'name': name, 'icon': icon, 'icon_height': '40px',
                        'show_state': False, 'color': 'primary' if path == active else 'grey',
                        'tap_action': {'action': 'navigate', 'navigation_path': f'/{PATH}/{path}'},
                        'hold_action': {'action': 'none'}, 'double_tap_action': {'action': 'none'}})
    return {'type': 'grid', 'column_span': 2,
            'cards': [{'type': 'horizontal-stack', 'cards': buttons,
                       'grid_options': {'columns': 'full', 'rows': 'auto'}}]}


def discover_instance(api):
    root = api.request('media_source/browse_media', media_content_id='media-source://frigate')
    instances = {urlparse(c.get('media_content_id', '')).path.strip('/').split('/')[0]
                 for c in root.get('children', []) if '/event-search/clips/' in c.get('media_content_id', '')}
    if len(instances) != 1:
        raise RuntimeError('Expected one enabled Frigate media source')
    return instances.pop()


def config(entities, temperatures, instance='frigate'):
    if len(set(entities)) != 2 or any(not re.fullmatch(r'camera\.[a-z0-9_]+', x) for x in entities):
        raise RuntimeError('Expected two distinct camera entities')
    if len(temperatures) != 4 or any(not re.fullmatch(r'sensor\.[a-z0-9_]+', t['entity']) for t in temperatures):
        raise RuntimeError('Expected four temperature sensor entities')
    cards = [navigation('live')]
    for index, entity in enumerate(entities, 1):
        cards.append({'type': 'grid', 'cards': [{
            'type': 'picture-entity', 'entity': entity, 'name': f'Kamera {index}',
            'camera_view': 'live', 'show_name': True, 'show_state': False,
            'fit_mode': 'contain', 'aspect_ratio': '16:9',
            'tap_action': {'action': 'none'}, 'hold_action': {'action': 'none'},
            'double_tap_action': {'action': 'none'},
        }]})
    cards.append({'type': 'grid', 'column_span': 2, 'cards': [{
        'type': 'custom:landet-clips-card', 'instance_id': instance,
        'grid_options': {'columns': 'full', 'rows': 'auto'},
        'cameras': {entity.removeprefix('camera.'): f'Kamera {i}' for i, entity in enumerate(entities, 1)}}]})
    readings = [navigation('temperature')]
    for thermometer in temperatures:
        readings.append({'type': 'grid', 'cards': [{'type': 'custom:landet-climate-card',
            'temperature': thermometer['entity'], 'humidity': thermometer.get('humidity'),
            'grid_options': {'columns': 'full', 'rows': 'auto'},
            'name': thermometer['name'], 'location': thermometer['location']}]})
    return {'kiosk_mode': {'kiosk': True, 'block_mouse': False, 'block_context_menu': True},
            'views': [{'title': 'Kameror', 'path': 'live', 'type': 'sections',
                       'max_columns': 2, 'sections': cards},
                      {'title': 'Temperatur', 'path': 'temperature', 'type': 'sections',
                       'max_columns': 2, 'sections': readings}]}


class API:
    def __init__(self, token):
        import websocket
        self.socket = websocket.create_connection('ws://127.0.0.1:8123/api/websocket', timeout=20)
        self.number = 0
        if json.loads(self.socket.recv()).get('type') != 'auth_required':
            raise RuntimeError('Unexpected authentication handshake')
        self.socket.send(json.dumps({'type': 'auth', 'access_token': token}))
        if json.loads(self.socket.recv()).get('type') != 'auth_ok':
            raise RuntimeError('Home Assistant authentication failed')

    def request(self, kind, **payload):
        self.number += 1
        self.socket.send(json.dumps({'id': self.number, 'type': kind, **payload}))
        while True:
            reply = json.loads(self.socket.recv())
            if reply.get('id') == self.number:
                if not reply.get('success'):
                    raise RuntimeError('Home Assistant rejected ' + kind)
                return reply.get('result')


def save_state(state):
    STATE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = STATE.with_suffix('.tmp')
    with temporary.open('w', encoding='utf-8') as output:
        os.chmod(temporary, 0o600)
        json.dump(state, output)
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(STATE)


def snapshot(api):
    dashboards = api.request('lovelace/dashboards/list')
    return {d['url_path']: api.request('lovelace/config', url_path=d['url_path'])
            for d in dashboards if d.get('mode') == 'storage' and d['url_path'] != PATH}


def validate(api, desired):
    if api.request('lovelace/config', url_path=PATH) != desired:
        raise RuntimeError('Dashboard configuration readback differs')
    resources = api.request('lovelace/resources')
    if not any(r.get('url') == URL and r.get('type') == 'module' for r in resources):
        raise RuntimeError('Kiosk resource registration is missing')
    if not FILE.is_file() or hashlib.sha256(FILE.read_bytes()).hexdigest() != DIGEST:
        raise RuntimeError('Pinned kiosk resource checksum differs')
    if not any(r.get('url') == UI_URL and r.get('type') == 'module' for r in resources):
        raise RuntimeError('Landet UI module registration is missing')
    if not UI_FILE.is_file() or hashlib.sha256(UI_FILE.read_bytes()).hexdigest() != UI_DIGEST:
        raise RuntimeError('Landet UI module checksum differs')
    print('Validated: cameras, temperature/humidity, date-selectable graphs, recent-clips card, hidden HA menus, local modules')
    print('Browser rendering and video playback still require owner preview')


def ensure_ui(api, state):
    if state.get('ui'):
        if state['ui']['digest'] != UI_DIGEST:
            raise RuntimeError('Frontend source changed; use --rollback then --apply to replace it safely')
        return
    if UI_FILE.exists() and hashlib.sha256(UI_FILE.read_bytes()).hexdigest() != UI_DIGEST:
        raise RuntimeError('Unexpected existing Landet UI file')
    created = not UI_FILE.exists()
    UI_FILE.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    if created:
        UI_FILE.write_bytes(UI_DATA)
        UI_FILE.chmod(0o644)
    try:
        matching = [r for r in api.request('lovelace/resources') if r.get('url') == UI_URL]
        if matching:
            raise RuntimeError('Landet UI registration exists without ownership state')
        resource = api.request('lovelace/resources/create', url=UI_URL, res_type='module')
    except Exception:
        if created:
            UI_FILE.unlink(missing_ok=True)
        raise
    state['ui'] = {'id': resource['id'], 'url': UI_URL, 'file': str(UI_FILE), 'digest': UI_DIGEST, 'created_file': created}
    save_state(state)


def rollback(api, state):
    # Refuse to remove a dashboard the owner has edited after deployment.
    dashboards = api.request('lovelace/dashboards/list')
    current = next((d for d in dashboards if d['url_path'] == PATH), None)
    if current:
        if current['id'] != state.get('dashboard_id'):
            raise RuntimeError('Dashboard ownership check failed')
        try:
            current_config = api.request('lovelace/config', url_path=PATH)
        except RuntimeError:
            if state.get('config_saved'):
                raise
            current_config = None
        if current_config is not None and current_config != state['config']:
            raise RuntimeError('Dashboard was edited; refusing automatic removal')
        api.request('lovelace/dashboards/delete', dashboard_id=current['id'])
    # A resource can be shared after installation. Keep it if another dashboard uses kiosk mode.
    shared = any('kiosk_mode' in c for c in snapshot(api).values())
    ui = state.get('ui')
    ui_shared = any(str(n.get('type', '')).startswith('custom:landet-')
                    for conf in snapshot(api).values() for n in walk(conf))
    if ui and not ui_shared:
        resources = api.request('lovelace/resources')
        resource = next((r for r in resources if r['id'] == ui['id']), None)
        if resource:
            if resource.get('url') != ui['url']:
                raise RuntimeError('Landet UI ownership check failed')
            api.request('lovelace/resources/delete', resource_id=resource['id'])
        ui_file = Path(ui['file'])
        if ui_file.parent != FILE.parent or not ui_file.name.startswith('landet-cards-'):
            raise RuntimeError('Unexpected Landet UI file path')
        if ui.get('created_file') and ui_file.exists():
            if hashlib.sha256(ui_file.read_bytes()).hexdigest() != ui['digest']:
                raise RuntimeError('Landet UI file was edited; refusing removal')
            ui_file.unlink()
    if state.get('resource_id') and not shared:
        resources = api.request('lovelace/resources')
        match = next((r for r in resources if r['id'] == state['resource_id']), None)
        if match:
            if match.get('url') != URL:
                raise RuntimeError('Resource ownership check failed')
            api.request('lovelace/resources/delete', resource_id=match['id'])
        if state.get('created_file') and FILE.exists():
            if hashlib.sha256(FILE.read_bytes()).hexdigest() != DIGEST:
                raise RuntimeError('Kiosk file was edited; refusing removal')
            FILE.unlink()
    STATE.unlink(missing_ok=True)
    print('Prototype dashboard removed; other dashboards and Cloudflare are unchanged')


def run(api, mode, entities):
    dashboards = api.request('lovelace/dashboards/list')
    existing = next((d for d in dashboards if d['url_path'] == PATH), None)
    resources = api.request('lovelace/resources')
    if mode == '--rollback':
        if not STATE.exists():
            if existing:
                raise RuntimeError('No ownership state; refusing to remove existing dashboard')
            print('Prototype is absent; nothing to roll back')
            return
        rollback(api, json.loads(STATE.read_text()))
        return
    states = {s['entity_id']: s for s in api.request('get_states')}
    if any(e not in states or states[e]['state'] in ('unavailable', 'unknown') for e in entities):
        raise RuntimeError('Both cameras must be available before dashboard deployment')
    temperatures = discover_temperatures(api, states)
    desired = config(entities, temperatures, discover_instance(api))
    if mode == '--dry-run':
        print('Would configure Kameror and Temperatur views with two navigation buttons and four thermometers')
        print(f'Would add checksum-pinned Kiosk Mode {VERSION} for this dashboard')
        print('Would add the local Landet cards module; clips/history use the logged-in HA session only')
        print('A Home Assistant restart is required if the /local file route is not enabled yet')
        print('Existing dashboards, accounts, defaults, DNS, Access policies, and tunnel routes remain unchanged')
        print(json.dumps(desired, indent=2, ensure_ascii=False))
        return
    if mode == '--validate':
        validate(api, desired)
        return
    if existing:
        if not STATE.exists() or json.loads(STATE.read_text()).get('dashboard_id') != existing['id']:
            raise RuntimeError('Dashboard already exists without matching ownership state')
        saved = json.loads(STATE.read_text())
        current = api.request('lovelace/config', url_path=PATH)
        if current != saved['config']:
            raise RuntimeError('Dashboard was edited outside this workflow; refusing replacement')
        if current != desired:
            before = snapshot(api)
            ensure_ui(api, saved)
            original_state = dict(saved)
            saved['previous_config'] = current
            save_state(saved)
            try:
                api.request('lovelace/config/save', url_path=PATH, config=desired)
                validate(api, desired)
                if snapshot(api) != before:
                    raise RuntimeError('Unrelated dashboard configuration changed')
                saved['config'] = desired
                save_state(saved)
            except Exception:
                api.request('lovelace/config/save', url_path=PATH, config=current)
                save_state(original_state)
                raise
            print('Dashboard updated; previous configuration retained in protected state')
        else:
            validate(api, desired)
            print('Already configured; no dashboard or resource changes')
        if json.loads(STATE.read_text()).get('frontend_restart_needed'):
            print('frontend_restart_needed=yes')
        return
    if STATE.exists():
        raise RuntimeError('Previous deployment state exists; use rollback before retrying')
    before = snapshot(api)
    state = {'config': desired, 'dashboard_id': None, 'resource_id': None, 'created_file': False,
             'config_saved': False, 'frontend_restart_needed': not Path('/config/www').is_dir()}
    if FILE.exists() and hashlib.sha256(FILE.read_bytes()).hexdigest() != DIGEST:
        raise RuntimeError('Existing kiosk file has unexpected contents')
    save_state(state)
    try:
        if not FILE.exists():
            with urllib.request.urlopen(ASSET, timeout=30) as response:
                data = response.read(2000001)
            if len(data) > 2000000 or hashlib.sha256(data).hexdigest() != DIGEST:
                raise RuntimeError('Downloaded kiosk module checksum differs')
            FILE.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            FILE.write_bytes(data)
            FILE.chmod(0o644)
            state['created_file'] = True
            save_state(state)
        matching = [r for r in resources if r.get('url') == URL]
        if matching and (len(matching) != 1 or matching[0].get('type') != 'module'):
            raise RuntimeError('Unexpected existing resource registration')
        if not matching:
            resource = api.request('lovelace/resources/create', url=URL, res_type='module')
            state['resource_id'] = resource['id']
            save_state(state)
        ensure_ui(api, state)
        dashboard = api.request('lovelace/dashboards/create', url_path=PATH, title='Landet',
                                icon='mdi:cctv', show_in_sidebar=True, require_admin=False)
        state['dashboard_id'] = dashboard['id']
        save_state(state)
        api.request('lovelace/config/save', url_path=PATH, config=desired)
        state['config_saved'] = True
        save_state(state)
        validate(api, desired)
        if snapshot(api) != before:
            raise RuntimeError('Unrelated dashboard configuration changed')
        print('Dashboard ready: /landet-view/live')
        if state['frontend_restart_needed']:
            print('frontend_restart_needed=yes')
    except Exception:
        try:
            rollback(api, state)
        except Exception:
            print('Automatic cleanup incomplete; protected ownership state retained', file=sys.stderr)
        raise


def main():
    from homeassistant.const import __version__
    version = tuple(int(x) for x in __version__.split('.')[:3])
    if os.environ['DASHBOARD_MODE'] != '--rollback' and not (2026, 10, 1) <= version < (2026, 11, 0):
        raise RuntimeError('Pinned kiosk version requires Home Assistant 2026.10.1 through 2026.10.x')
    mode = os.environ['DASHBOARD_MODE']
    if not UI_DATA and mode != '--rollback':
        raise RuntimeError('Landet frontend source is missing')
    if mode not in ('--dry-run', '--apply', '--validate', '--rollback'):
        raise RuntimeError('Unsupported mode')
    api = API(os.environ['HASS_TOKEN'])
    try:
        run(api, mode, [os.environ['C200_ENTITY'], os.environ['C320WS_ENTITY']])
    finally:
        api.socket.close()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Do not expose request payloads, session tokens, or raw remote responses.
        detail = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print('ERROR: dashboard operation failed (' + detail + ')', file=sys.stderr)
        sys.exit(1)
