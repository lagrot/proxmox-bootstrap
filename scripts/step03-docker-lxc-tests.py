#!/usr/bin/env python3
"""Exercise CT200 bootstrap using isolated files and fake Proxmox commands."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for directory in ('scripts', 'config', 'lib', 'bin', 'templates', 'media'):
            (self.root / directory).mkdir()
        for name in ('common.sh', 'logging.sh', 'cli.sh', 'runtime.sh', 'validation.sh'):
            shutil.copy(REPO / 'lib' / name, self.root / 'lib' / name)
        shutil.copy(REPO / 'config/defaults.conf', self.root / 'config/defaults.conf')
        script = (REPO / 'scripts/step03-docker-lxc.sh').read_text()
        script = script.replace('/var/lib/vz/template/cache/', str(self.root / 'templates') + '/')
        script = script.replace('/mnt/frigate', str(self.root / 'media'))
        (self.root / 'scripts/step03-docker-lxc.sh').write_text(script)
        (self.root / 'templates/debian-13-standard_13.1-2_amd64.tar.zst').touch()
        fake = '''#!/bin/bash
printf '%s %s\\n' "$(basename "$0")" "$*" >> "$EVENTS"
case "$(basename "$0")" in
 pct) case "$1" in
   status) [[ -f "$STATE" ]] ;;
   config) echo 'hostname: docker-core' ;;
   create) touch "$STATE" ;;
   *) exit 2 ;;
 esac ;;
 pvesm) printf 'Name Type Status\\nlocal dir active\\nlocal-lvm lvmthin active\\n' ;;
 pveversion) echo 'pve test' ;;
 pveam|ip) exit 0 ;;
esac
'''
        for name in ('pct', 'pvesm', 'pveversion', 'pveam', 'ip'):
            path = self.root / 'bin' / name
            path.write_text(fake)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / 'bin') + ':' + os.environ['PATH'],
                        EVENTS=str(self.root / 'events'), STATE=str(self.root / 'state'),
                        LOG_FILE=str(self.root / 'operation.log'))

    def run_script(self, *args):
        return subprocess.run(['bash', str(self.root / 'scripts/step03-docker-lxc.sh'), *args],
                              env=self.env, text=True, capture_output=True)

    def events(self):
        return (self.root / 'events').read_text() if (self.root / 'events').exists() else ''

    def test_preview_prints_32_gib_and_does_not_create(self):
        result = self.run_script('--dry-run')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('--rootfs local-lvm:32', result.stdout)
        self.assertNotIn('pct create', self.events())
        self.assertFalse((self.root / 'state').exists())
        self.assertFalse((self.root / 'operation.log').exists())

    def test_create_and_existing_guest(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('--rootfs local-lvm:32', self.events())
        before = self.events().count('pct create')
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.events().count('pct create'), before)

    def test_missing_template_and_bad_option_do_not_create(self):
        (self.root / 'templates/debian-13-standard_13.1-2_amd64.tar.zst').unlink()
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertNotEqual(self.run_script('--invalid').returncode, 0)
        self.assertNotIn('pct create', self.events())


if __name__ == '__main__':
    unittest.main()
