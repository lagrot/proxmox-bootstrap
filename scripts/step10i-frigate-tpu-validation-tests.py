#!/usr/bin/env python3
"""Exercise Step 10I Coral validation with a fake Proxmox command."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/step10i-frigate-tpu-validation.sh"


class FrigateTpuValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "bin").mkdir()
        self.config = self.root / "config.yml"
        self.config.write_text("detectors:\n  coral:\n    type: edgetpu\n    device: usb\n")
        pct = self.root / "bin/pct"
        pct.write_text(r'''#!/bin/bash
case "$1" in
  status)
    [[ "$STATUS_FAIL" != 1 ]] || { echo 'permission denied to Proxmox IPC' >&2; exit 1; }
    [[ "$STATUS_STOPPED" == 1 ]] && echo 'status: stopped' || echo 'status: running' ;;
  exec)
    shift 3
    case "$1" in
      grep) args=("${@:2}"); for i in "${!args[@]}"; do [[ "${args[$i]}" != /opt/frigate/config/config.yml ]] || args[$i]="$TEST_CONFIG"; done; grep "${args[@]}" ;;
      docker)
        if [[ "$2" == exec && "$3" == frigate && "$4" == test ]]; then
          [[ "$USB_VISIBLE" == 1 ]]
        elif [[ "$2" == logs ]]; then
          [[ "$LOG_FAIL" != 1 ]] || exit 1
          [[ " ${*:2} " == *" --tail 1000 "* ]] || exit 9
          printf '%s\n' "$LOG_TEXT"
        elif [[ "$2" == exec && "$3" == frigate && "$4" == python3 ]]; then
          [[ "$STATS_FAIL" != 1 ]] || exit 1
          printf '%s\n' "$STATS_JSON"
        else exit 1
        fi ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
''')
        pct.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.root / 'bin'}:{os.environ['PATH']}",
                        TEST_CONFIG=str(self.config), STATUS_FAIL="0", STATUS_STOPPED="0",
                        USB_VISIBLE="1", LOG_FAIL="0", STATS_FAIL="0", LOG_TEXT="",
                        STATS_JSON='{"detectors":{"coral":{"inference_speed":24.3,"pid":123}}}')

    def run_script(self, **overrides):
        return subprocess.run(["bash", str(SCRIPT)], env=dict(self.env, **overrides),
                              text=True, capture_output=True)

    def test_live_stats_pass_when_initialization_logs_are_absent(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Live Coral detector stats: inference_speed=24.3|pid=123", result.stdout)
        self.assertIn("live Coral statistics confirm it is active", result.stdout)
        self.assertNotIn("Validation errors: 1", result.stdout)

    def test_recent_error_is_warning_only_when_detector_is_live(self):
        error = "Coral detector error: delegate failed"
        recovered = self.run_script(LOG_TEXT=error)
        self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
        self.assertIn("live Coral detector is active", recovered.stdout)
        failed = self.run_script(LOG_TEXT=error, STATS_JSON='{"detectors":{}}')
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("contain Coral/EdgeTPU errors", failed.stdout)

    def test_status_error_is_distinct_from_stopped_ct_and_bad_input_is_early(self):
        query_error = self.run_script(STATUS_FAIL="1")
        self.assertNotEqual(query_error.returncode, 0)
        self.assertIn("Could not query status", query_error.stdout)
        self.assertNotIn("is not running", query_error.stdout)
        stopped = self.run_script(STATUS_STOPPED="1")
        self.assertNotEqual(stopped.returncode, 0)
        self.assertIn("CT 200 is not running", stopped.stdout)
        invalid = self.run_script(FRIGATE_TPU_LOG_LOOKBACK="0h")
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("positive duration", invalid.stdout)

    def test_malformed_or_unavailable_stats_and_log_failures_do_not_pass_silently(self):
        malformed = self.run_script(STATS_JSON="not-json")
        self.assertNotEqual(malformed.returncode, 0)
        self.assertIn("not valid detector data", malformed.stdout)
        inactive = self.run_script(STATS_JSON='{"detectors":{"coral":{"inference_speed":0,"pid":123}}}')
        self.assertNotEqual(inactive.returncode, 0)
        self.assertIn("do not show an active process", inactive.stdout)
        unavailable = self.run_script(STATS_FAIL="1")
        self.assertNotEqual(unavailable.returncode, 0)
        self.assertIn("Could not read live Frigate stats", unavailable.stdout)
        log_failure = self.run_script(LOG_FAIL="1")
        self.assertEqual(log_failure.returncode, 0, log_failure.stdout + log_failure.stderr)
        self.assertIn("Could not read recent Frigate logs", log_failure.stdout)
        self.assertNotIn("No recent Coral/EdgeTPU initialization errors", log_failure.stdout)

    def test_config_and_usb_failure_are_errors(self):
        self.config.write_text("detectors:\n  coral:\n    type: edgetpu\n    device: pci\n")
        config_fail = self.run_script()
        self.assertNotEqual(config_fail.returncode, 0)
        self.assertIn("USB Coral EdgeTPU detector", config_fail.stdout)
        usb_fail = self.run_script(USB_VISIBLE="0")
        self.assertNotEqual(usb_fail.returncode, 0)
        self.assertIn("USB device bus is not visible", usb_fail.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
