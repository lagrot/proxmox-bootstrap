#!/usr/bin/env python3
"""Exercise reversible dashboard deployment with an isolated fake HA API."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('landet', Path(__file__).resolve().parents[1] / 'lib/landet_dashboard.py')
landet = importlib.util.module_from_spec(spec)
spec.loader.exec_module(landet)
ENTITIES = ['camera.tplink_c200_1', 'camera.tplink_c320ws_1']
TEMPS = [dict(entity='sensor.temperature_' + str(i), name=name, location='Inomhus' if i < 3 else 'Utomhus', humidity='sensor.humidity_' + str(i) if i < 3 else None) for i, name in enumerate(['Living Room', 'Bedroom', 'Eagles Nest', 'Outside'])]


class FakeAPI:
    def __init__(self):
        self.dashboards = [{'id': 'original', 'url_path': 'frigate-dashboard', 'mode': 'storage'}]
        self.configs = {'frigate-dashboard': {'views': [{'title': 'Original'}]}}
        for path, thermometers in [('climate-dashboard', TEMPS[:3]), ('outdoor-climate', TEMPS[3:])]:
            self.dashboards.append({'id': path, 'url_path': path, 'mode': 'storage'})
            self.configs[path] = {'views': [{'sections': [{'cards': [{'type': 'heading', 'heading': t['name']}, {'type': 'sensor', 'entity': t['entity']}, *([{'type':'sensor', 'entity':t['humidity']}] if t['humidity'] else [])]} for t in thermometers]}]}
        self.resources = []
        self.calls = []
        self.fail_save = False

    def request(self, kind, **data):
        self.calls.append(kind)
        if kind == 'get_states':
            return ([{'entity_id': e, 'state': 'recording'} for e in ENTITIES]
                    + [{'entity_id': t['entity'], 'state': '21.5', 'attributes': {'device_class': 'temperature', 'unit_of_measurement': '°C'}} for t in TEMPS]
                    + [{'entity_id':t['humidity'], 'state':'50', 'attributes':{'device_class':'humidity'}} for t in TEMPS if t['humidity']])
        if kind == 'media_source/browse_media': return {'children':[{'media_content_id':'media-source://frigate/frigate/event-search/clips//////'}]}
        if kind == 'lovelace/dashboards/list': return copy.deepcopy(self.dashboards)
        if kind == 'lovelace/resources': return copy.deepcopy(self.resources)
        if kind == 'lovelace/config':
            if data['url_path'] not in self.configs: raise RuntimeError('No config yet')
            return copy.deepcopy(self.configs[data['url_path']])
        if kind == 'lovelace/resources/create':
            resource = {'id': 'owned-resource-' + str(len(self.resources)), 'url': data['url'], 'type': data['res_type']}
            self.resources.append(resource)
            return copy.deepcopy(resource)
        if kind == 'lovelace/dashboards/create':
            dashboard = dict(data, id='owned-dashboard', mode='storage')
            self.dashboards.append(dashboard)
            return copy.deepcopy(dashboard)
        if kind == 'lovelace/config/save':
            if self.fail_save:
                self.fail_save = False
                raise RuntimeError('Simulated save failure')
            self.configs[data['url_path']] = copy.deepcopy(data['config'])
            return None
        if kind == 'lovelace/dashboards/delete':
            found = next(d for d in self.dashboards if d['id'] == data['dashboard_id'])
            self.dashboards.remove(found)
            self.configs.pop(found['url_path'], None)
            return None
        if kind == 'lovelace/resources/delete':
            self.resources = [r for r in self.resources if r['id'] != data['resource_id']]
            return None
        raise AssertionError(kind)


class DashboardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.file = self.root / 'www/module.js'
        self.state = self.root / 'state/owned.json'
        self.api = FakeAPI()
        self.original = copy.deepcopy(self.api.configs)
        self.bundle = b'/* pinned test module */'
        self.ui = self.root / 'www/landet-cards-test.js'
        self.ui_data = b'/* local frontend */'
        for name, value in [('FILE', self.file), ('STATE', self.state), ('DIGEST', hashlib.sha256(self.bundle).hexdigest()), ('UI_FILE', self.ui), ('UI_DATA', self.ui_data), ('UI_DIGEST', hashlib.sha256(self.ui_data).hexdigest())]:
            patched = patch.object(landet, name, value)
            patched.start()
            self.addCleanup(patched.stop)

    def run_mode(self, mode, bundle=None):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()), \
             patch.object(landet.urllib.request, 'urlopen', return_value=io.BytesIO(self.bundle if bundle is None else bundle)):
            landet.run(self.api, mode, ENTITIES)

    def test_preview_has_no_writes_or_downloads(self):
        self.run_mode('--dry-run')
        self.assertFalse(self.file.exists())
        self.assertFalse(self.state.exists())
        self.assertEqual(self.api.configs, self.original)
        self.assertFalse(any(x.endswith(('/create', '/save', '/delete')) for x in self.api.calls))

    def test_apply_is_idempotent_and_preserves_original(self):
        self.run_mode('--apply')
        count = len(self.api.calls)
        self.run_mode('--apply')
        self.assertFalse(any(x.endswith(('/create', '/save', '/delete')) for x in self.api.calls[count:]))
        self.assertEqual(self.api.configs['frigate-dashboard'], self.original['frigate-dashboard'])
        self.assertTrue(self.ui.exists())
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)

    def test_rollback_removes_only_owned_components(self):
        self.run_mode('--apply')
        self.run_mode('--rollback')
        self.run_mode('--rollback')
        self.assertEqual(self.api.configs, self.original)
        self.assertEqual(self.api.resources, [])
        self.assertFalse(self.file.exists())
        self.assertFalse(self.state.exists())

    def test_bad_download_fails_without_dashboard(self):
        with self.assertRaises(RuntimeError): self.run_mode('--apply', b'tampered')
        self.assertEqual(self.api.configs, self.original)
        self.assertFalse(self.state.exists())

    def test_failed_save_rolls_back_partial_creation(self):
        self.api.fail_save = True
        with self.assertRaises(RuntimeError): self.run_mode('--apply')
        self.assertEqual(self.api.configs, self.original)
        self.assertEqual(self.api.resources, [])
        self.assertFalse(self.state.exists())

    def test_edited_dashboard_is_preserved(self):
        self.run_mode('--apply')
        self.api.configs[landet.PATH]['views'][0]['title'] = 'Owner edit'
        with self.assertRaises(RuntimeError): self.run_mode('--rollback')
        self.assertTrue(self.state.exists())
        self.assertIn(landet.PATH, self.api.configs)

    def test_shared_resource_is_preserved(self):
        self.run_mode('--apply')
        self.api.configs['frigate-dashboard']['kiosk_mode'] = {'kiosk': True}
        self.run_mode('--rollback')
        self.assertEqual(len(self.api.resources), 1)
        self.assertTrue(self.file.exists())

    def test_only_navigation_buttons_are_interactive(self):
        conf = landet.config(ENTITIES, TEMPS)
        for view in conf['views']:
            buttons = view['sections'][0]['cards'][0]['cards']
            self.assertEqual([b['name'] for b in buttons], ['Kameror', 'Temperatur'])
            for button in buttons:
                self.assertEqual(button['tap_action']['action'], 'navigate')
                self.assertIn(button['tap_action']['navigation_path'], ['/landet-view/live', '/landet-view/temperature'])
                self.assertEqual(button['hold_action'], {'action': 'none'})
        temperatures = conf['views'][1]['sections'][1:]
        self.assertEqual(len(temperatures), 4)
        self.assertTrue(all(s['cards'][0]['type'] == 'custom:landet-climate-card' for s in temperatures))

    def test_owned_configuration_update_and_previous_backup(self):
        self.run_mode('--apply')
        previous = copy.deepcopy(self.api.configs[landet.PATH])
        previous['views'] = previous['views'][:1]
        self.api.configs[landet.PATH] = previous
        saved = json.loads(self.state.read_text())
        saved['config'] = previous
        self.state.write_text(json.dumps(saved))
        self.run_mode('--apply')
        self.assertEqual(len(self.api.configs[landet.PATH]['views']), 2)
        self.assertEqual(json.loads(self.state.read_text())['previous_config'], previous)

    def test_failed_update_restores_working_dashboard(self):
        self.run_mode('--apply')
        previous = copy.deepcopy(self.api.configs[landet.PATH])
        previous['views'] = previous['views'][:1]
        self.api.configs[landet.PATH] = previous
        saved = json.loads(self.state.read_text())
        saved['config'] = previous
        self.state.write_text(json.dumps(saved))
        self.api.fail_save = True
        with self.assertRaises(RuntimeError): self.run_mode('--apply')
        self.assertEqual(self.api.configs[landet.PATH], previous)
        self.assertEqual(json.loads(self.state.read_text()), saved)

    def test_cards_have_no_controls_or_actions(self):
        conf = landet.config(ENTITIES, TEMPS)
        self.assertEqual(len(conf['views']), 2)
        self.assertFalse(conf['kiosk_mode']['block_mouse'])
        cards = [s['cards'][0] for s in conf['views'][0]['sections'][1:3]]
        self.assertEqual([c['entity'] for c in cards], ENTITIES)
        for card in cards:
            self.assertEqual(card['camera_view'], 'live')
            for action in ('tap_action', 'hold_action', 'double_tap_action'):
                self.assertEqual(card[action], {'action': 'none'})
        with self.assertRaises(RuntimeError): landet.config(['switch.test', ENTITIES[1]], TEMPS)


if __name__ == '__main__':
    unittest.main()
