#!/usr/bin/env python3
"""Offline recovery fingerprint and non-mutating CLI contract tests."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('recovery', REPO/'lib/landet_recovery.py')
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in recovery.ROOTS:
            path = self.root/name
            path.parent.mkdir(parents=True, exist_ok=True)
            if name in ('etc/landet', 'etc/nginx', 'opt/landet', 'var/lib/landet-deploy'):
                path.mkdir()
            else:
                path.write_text('sample')
        for name, mode in [('viewer.env', 0o600), ('relay.json', 0o640)]:
            path = self.root/'etc/landet'/name
            path.write_text('fictional secret')
            path.chmod(mode)
        (self.root/'opt/landet/current').symlink_to('/opt/landet/releases/1234')
        self.manifest = self.root/'manifest.json'
        self.manifest.write_text(json.dumps(recovery.fingerprint(self.root)))

    def verify(self):
        return subprocess.run(['python3', str(REPO/'lib/landet_recovery.py'),
                               'verify', str(self.root), str(self.manifest)],
                              capture_output=True, text=True)

    def test_restore_matches_and_preserves_absolute_symlink(self):
        self.assertEqual(self.verify().returncode, 0)

    def test_secret_corruption_fails_without_disclosing_value(self):
        (self.root/'etc/landet/viewer.env').write_text('changed private value')
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('changed private value', result.stdout+result.stderr)

    def test_public_secret_permissions_fail(self):
        (self.root/'etc/landet/viewer.env').chmod(0o644)
        self.assertNotEqual(self.verify().returncode, 0)

    def test_missing_release_fails(self):
        (self.root/'opt/landet/current').unlink()
        self.assertNotEqual(self.verify().returncode, 0)

    def test_missing_unit_fails(self):
        (self.root/'etc/systemd/system/landet.service').unlink()
        self.assertNotEqual(self.verify().returncode, 0)

    def test_cli_preview_never_calls_guest_tools(self):
        bin_dir = self.root/'bin'; bin_dir.mkdir()
        for command in ('pct', 'vzdump', 'pvesm'):
            path = bin_dir/command
            path.write_text('#!/bin/sh\necho MUTATED >&2\nexit 99\n'); path.chmod(0o755)
        env = dict(os.environ, PATH=f'{bin_dir}:'+os.environ['PATH'])
        result = subprocess.run(['bash', str(REPO/'scripts/step24-landet-recovery.sh'), '--dry-run'], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertNotIn('MUTATED', result.stderr)

    def test_ct240_audit_uses_security_only_engine(self):
        source = (REPO/'scripts/step20a-update-audit.sh').read_text()
        function = source[source.index('package_audit() {'):source.index('guest_ha_info() {')]
        command = function + r'''
UPDATE_AUDIT_REFRESH=0
log_info(){ :; }; log_warn(){ :; }; record_error(){ exit 90; }
pct(){
 if [[ "$*" == "exec 240 -- unattended-upgrade --dry-run --verbose" ]]; then
  echo 'Packages that will be upgraded: nginx'; return
 fi
 [[ "$*" == "exec 240 -- apt-get -s dist-upgrade" ]] || return 99
 printf "%s\n" "Inst nginx [1] (2 Debian-Security:13/stable-security [amd64])" "Inst example [1] (2 Debian:13/stable [amd64])"
}
package_audit "CT 240" 240 ct_updates ct_security
[[ "$ct_updates" == 2 && "$ct_security" == 1 ]]
'''
        result = subprocess.run(['bash', '-c', command], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_audit_metadata_failure_is_reported(self):
        source = (REPO/'scripts/step20a-update-audit.sh').read_text()
        function = source[source.index('package_audit() {'):source.index('guest_ha_info() {')]
        command = function + r'''
UPDATE_AUDIT_REFRESH=1; errors=0; ct_updates=0; ct_security=0
log_info(){ :; }; log_warn(){ :; }; record_error(){ errors=$((errors+1)); }
pct(){ return 1; }
package_audit "CT 240" 240 ct_updates ct_security
[[ "$errors" == 1 && "$ct_updates" == 0 && "$ct_security" == 0 ]]
'''
        result = subprocess.run(['bash', '-c', command], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cli_invalid_input(self):
        for args in ([], ['--bad'], ['--backup'], ['--dry-run', 'extra'], ['--restore-test', '/does-not-exist']):
            result = subprocess.run(['bash', str(REPO/'scripts/step24-landet-recovery.sh'), *args], capture_output=True)
            self.assertEqual(result.returncode, 2, args)


if __name__ == '__main__':
    unittest.main()
