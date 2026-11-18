#!/usr/bin/env python3
"""Exercise the Step 10K HACS bootstrap wrapper without touching HAOS."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/step10k-homeassistant-hacs-bootstrap.sh"


class HacsBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "bin").mkdir()
        qm = self.root / "bin/qm"
        qm.write_text(r'''#!/bin/bash
printf '%s\n' "$*" >> "$QM_CALLS"
case "$1" in
  status)
    [[ "$STATUS_FAIL" != 1 ]] || { echo 'permission denied to Proxmox IPC' >&2; exit 1; }
    [[ "$STATUS_STOPPED" == 1 ]] && echo 'status: stopped' || echo 'status: running' ;;
  guest)
    if [[ "$*" == *'/usr/bin/ha store add '* ]]; then echo '{"exitcode":0,"out-data":"repository added"}'
    elif [[ "$*" == *'/usr/bin/ha store reload'* ]]; then echo '{"exitcode":0,"out-data":"reloaded"}'
    elif [[ "$*" == *'/usr/bin/ha store apps install '* ]]; then
      [[ "$APP_MODE" == success ]] && echo '{"exitcode":0,"out-data":"installed"}' \
        || echo '{"exitcode":1,"err-data":"app unavailable"}'
    elif [[ "$*" == *'/usr/bin/ha core restart'* ]]; then echo '{"exitcode":0,"out-data":"restart requested"}'
    elif [[ "$*" == *'/bin/bash -c '* ]]; then
      [[ "$APP_MODE" == fallback ]] || exit 1
      echo '{"exitcode":0,"out-data":"HACS integration installed from the official release"}'
    else exit 1; fi ;;
  *) exit 1 ;;
esac
''')
        qm.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.root / 'bin'}:{os.environ['PATH']}",
                        QM_CALLS=str(self.root / "qm-calls"), STATUS_FAIL="0", STATUS_STOPPED="0",
                        APP_MODE="success")

    def run_script(self, *args, **overrides):
        return subprocess.run(["bash", str(SCRIPT), *args], env=dict(self.env, **overrides),
                              text=True, capture_output=True)

    def qm_calls(self):
        path = self.root / "qm-calls"
        return path.read_text() if path.exists() else ""

    def test_documented_dry_run_has_no_guest_or_vm_calls(self):
        result = self.run_script("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("No changes were made", result.stdout)
        self.assertIn("Would request a Home Assistant Core restart", result.stdout)
        self.assertEqual(self.qm_calls(), "")

    def test_invalid_arguments_and_configuration_stop_before_qm(self):
        bad_arg = self.run_script("--unknown")
        self.assertEqual(bad_arg.returncode, 2)
        self.assertEqual(self.qm_calls(), "")
        too_many = self.run_script("--dry-run", "extra")
        self.assertEqual(too_many.returncode, 2)
        bad_repo = self.run_script("--dry-run", HACS_APP_REPOSITORY="http://example.invalid/repo")
        self.assertEqual(bad_repo.returncode, 2)
        self.assertEqual(self.qm_calls(), "")

    def test_vm_status_query_error_and_stopped_vm_are_distinct(self):
        query_error = self.run_script(STATUS_FAIL="1")
        self.assertNotEqual(query_error.returncode, 0)
        self.assertIn("Could not query Home Assistant VM", query_error.stdout)
        self.assertNotIn("is not running", query_error.stdout)
        stopped = self.run_script(STATUS_STOPPED="1")
        self.assertNotEqual(stopped.returncode, 0)
        self.assertIn("Home Assistant VM 100 is not running", stopped.stdout)
        self.assertNotIn("Could not query", stopped.stdout)

    def test_app_success_restarts_core_and_fallback_path_is_transactional(self):
        success = self.run_script()
        self.assertEqual(success.returncode, 0, success.stdout + success.stderr)
        self.assertIn("Get HACS app is installed", success.stdout)
        self.assertIn("Home Assistant Core restart requested", success.stdout)
        self.assertIn("/usr/bin/ha core restart", self.qm_calls())

        self.root.joinpath("qm-calls").unlink()
        fallback = self.run_script(APP_MODE="fallback")
        self.assertEqual(fallback.returncode, 0, fallback.stdout + fallback.stderr)
        self.assertIn("official release", fallback.stdout)
        calls = self.qm_calls()
        self.assertIn("unzip -tq", calls)
        self.assertIn(".hacs-stage.XXXXXX", calls)
        self.assertIn("hacs.previous", calls)
        self.assertIn("mv \"$backup_dir\" \"$hacs_dir\"", calls)

    def test_install_failure_does_not_request_core_restart(self):
        result = self.run_script(APP_MODE="broken")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("/usr/bin/ha core restart", self.qm_calls())


if __name__ == "__main__":
    unittest.main(verbosity=2)
