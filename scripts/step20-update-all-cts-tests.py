#!/usr/bin/env python3
"""Exercise the coordinator with an isolated fake per-container updater."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent / 'step20-update-all-cts.sh'


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        code = SOURCE.read_text().replace('/run/lock/proxmox-bootstrap-update-all.lock', str(self.root / 'lock'))
        (self.root / SOURCE.name).write_text(code)
        (self.root / 'step20-update-ct.sh').write_text(
            'printf "%s %s\\n" "$1" "$2" >> "${TEST_EVENTS}"\n'
            '[[ "$1" != "${TEST_FAIL:-}" ]] || exit 17\n')
        self.env = dict(os.environ, TEST_EVENTS=str(self.root / 'events'))

    def run_mode(self, *args, **env):
        return subprocess.run(['bash', str(self.root / SOURCE.name), *args],
                              env=dict(self.env, **env), text=True, capture_output=True)

    def events(self):
        path = self.root / 'events'
        return path.read_text().splitlines() if path.exists() else []

    def test_preview_is_read_only(self):
        self.assertEqual(self.run_mode('--dry-run').returncode, 0)
        self.assertEqual(self.events(), [])
        self.assertFalse((self.root / 'lock').exists())

    def test_invalid_input(self):
        for args in ((), ('--wrong',), ('--confirm', '--dry-run')):
            self.assertEqual(self.run_mode(*args).returncode, 2)
        self.assertEqual(self.events(), [])

    def test_order_and_failure_stop(self):
        result = self.run_mode('--confirm', TEST_FAIL='ct200')
        self.assertEqual(result.returncode, 17)
        self.assertEqual(self.events(), ['ct210 --confirm', 'ct220 --confirm', 'ct200 --confirm'])
        self.assertIn('later containers were not attempted', result.stderr)

    def test_success(self):
        self.assertEqual(self.run_mode('--confirm').returncode, 0)
        self.assertEqual(self.events(), [f'{t} --confirm' for t in ('ct210', 'ct220', 'ct200', 'ct240', 'ct230')])


if __name__ == '__main__':
    unittest.main()
