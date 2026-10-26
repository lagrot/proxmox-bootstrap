#!/usr/bin/env python3
"""Isolated camera NTP transaction and ONVIF parsing checks."""
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('camera_ntp', Path(__file__).resolve().parents[1] / 'lib/camera_ntp.py')
ntp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ntp)


class FakeCamera:
    def __init__(self):
        self.current = {'dhcp': True, 'manual': []}
        self.writes = []
        self.clock_mode = 'NTP'
        self.fail_validate = False
        self.reboots = 0
        self.reset_readback = False

    def settings(self):
        return self.current

    def inspect(self):
        return dict(mode=self.clock_mode, utc=dt.datetime.now(dt.timezone.utc), timezone='GMT-01:00', daylight_savings='true')

    def set_ntp(self, settings):
        self.writes.append(settings)
        self.current = settings

    def validate(self, server):
        if self.fail_validate or self.current != ntp.desired_settings(server):
            raise RuntimeError('Not synchronized')

    def call(self, action):
        assert action == 'SystemReboot'
        self.reboots += 1
        if self.reset_readback:
            self.current = {'dhcp': True, 'manual': []}

    def validate_clock(self, server):
        if self.fail_validate:
            raise RuntimeError('Not synchronized')


class CameraTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name) / 'state'
        self.camera = FakeCamera()
        self.env = dict(TAPO_C200_IP='192.168.8.107', TAPO_C200_USERNAME='test-user', TAPO_C200_PASSWORD='test-secret')

    def run_mode(self, mode, profile='c200'):
        output = io.StringIO()
        with patch.object(ntp, 'STATE_ROOT', self.state), patch.object(ntp, 'Camera', return_value=self.camera), \
             patch.object(ntp, 'ntp_client_requests', side_effect=lambda ip: self.camera.reboots), \
             patch.object(ntp.time, 'sleep'), patch.dict(os.environ, self.env, clear=True), \
             patch.object(ntp.sys, 'argv', ['camera_ntp.py', mode, profile, '192.168.8.10']), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            ntp.main()
        self.assertNotIn('test-secret', output.getvalue())

    def test_preview_is_read_only(self):
        self.run_mode('--dry-run')
        self.assertFalse(self.state.exists())
        self.assertEqual(self.camera.writes, [])

    def test_inspect_is_read_only(self):
        self.run_mode('--inspect')
        self.assertFalse(self.state.exists())
        self.assertEqual(self.camera.writes, [])

    def test_apply_and_idempotency(self):
        self.run_mode('--apply')
        self.run_mode('--apply')
        self.assertEqual(self.camera.writes, [ntp.desired_settings('192.168.8.10')])
        saved = self.state / 'c200.json'
        self.assertEqual(saved.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(saved.read_text())['ntp'], {'dhcp': True, 'manual': []})
        self.assertNotIn('test-secret', saved.read_text())

    def test_failed_acceptance_restores_original(self):
        self.camera.fail_validate = True
        with self.assertRaises(RuntimeError):
            self.run_mode('--apply')
        self.assertEqual(len(self.camera.writes), 2)
        self.assertEqual(self.camera.current, {'dhcp': True, 'manual': []})

    def test_explicit_rollback(self):
        self.run_mode('--apply')
        self.run_mode('--rollback')
        self.assertEqual(self.camera.current, {'dhcp': True, 'manual': []})

    def test_explicit_reboot_pilot_and_idempotency(self):
        self.run_mode('--apply-reboot')
        self.run_mode('--apply-reboot')
        self.assertEqual(self.camera.reboots, 1)
        self.assertEqual(self.camera.current, ntp.desired_settings('192.168.8.10'))

    def test_failed_reboot_pilot_restores_settings(self):
        self.camera.fail_validate = True
        with self.assertRaises(RuntimeError):
            self.run_mode('--apply-reboot')
        self.assertEqual(self.camera.reboots, 1)
        self.assertEqual(self.camera.current, {'dhcp': True, 'manual': []})

    def test_reboot_default_readback_needs_real_sync_evidence(self):
        self.camera.reset_readback = True
        self.run_mode('--apply-reboot')
        self.assertEqual(len(self.camera.writes), 1)
        self.run_mode('--apply-reboot')
        self.assertEqual(self.camera.reboots, 1)
        self.run_mode('--validate-sync')
        self.camera.reboots = 0
        with self.assertRaises(RuntimeError):
            self.run_mode('--validate-sync')

    def test_c320ws_rollout_after_configuration(self):
        self.env.update(TAPO_C320WS_IP='192.168.8.110', TAPO_C320WS_USERNAME='test-user', TAPO_C320WS_PASSWORD='test-secret')
        self.run_mode('--dry-run', 'c320ws')
        self.run_mode('--apply', 'c320ws')
        self.assertEqual(self.camera.reboots, 0)
        self.camera.reset_readback = True
        self.run_mode('--apply-reboot', 'c320ws')
        self.assertEqual(self.camera.reboots, 1)
        self.run_mode('--validate-sync', 'c320ws')

    def test_manual_clock_mode_is_rejected(self):
        self.camera.clock_mode = 'Manual'
        with self.assertRaises(RuntimeError):
            self.run_mode('--apply')
        self.assertEqual(self.camera.writes, [])

    def test_old_state_is_not_overwritten(self):
        self.state.mkdir()
        (self.state / 'c200.json').write_text('{}')
        with self.assertRaises(RuntimeError):
            self.run_mode('--apply')
        self.assertEqual(self.camera.writes, [])

    def test_rollback_rejects_wrong_camera(self):
        self.state.mkdir()
        (self.state / 'c200.json').write_text(json.dumps({'ip': '192.168.8.110'}))
        with self.assertRaises(RuntimeError):
            self.run_mode('--rollback')
        self.assertEqual(self.camera.writes, [])

    def test_missing_credentials(self):
        self.env.pop('TAPO_C200_PASSWORD')
        with self.assertRaises(RuntimeError):
            self.run_mode('--apply')
        self.assertEqual(self.camera.writes, [])

    def test_parse_ntp_settings(self):
        reply = ET.fromstring(f'<r xmlns:d="{ntp.DEVICE}" xmlns:t="{ntp.SCHEMA}"><d:NTPInformation><t:FromDHCP>false</t:FromDHCP><t:NTPManual><t:Type>IPv4</t:Type><t:IPv4Address>192.168.8.10</t:IPv4Address></t:NTPManual></d:NTPInformation></r>')
        self.assertEqual(ntp.ntp_settings(reply), ntp.desired_settings('192.168.8.10'))
        with self.assertRaises(RuntimeError):
            ntp.ntp_settings(ET.fromstring('<r/>'))

    def test_validation_rejects_stale_clock(self):
        self.camera.current = ntp.desired_settings('192.168.8.10')
        status = self.camera.inspect()
        status['utc'] -= dt.timedelta(days=1)
        with patch.object(self.camera, 'inspect', return_value=status):
            with self.assertRaises(RuntimeError):
                ntp.Camera.validate_clock(self.camera, '192.168.8.10')


if __name__ == '__main__':
    unittest.main()
