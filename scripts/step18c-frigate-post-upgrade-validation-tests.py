#!/usr/bin/env python3
"""Exercise Step 18C argument, backup, and validator routing without Proxmox."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
VALIDATORS = (
    "step04b-frigate-validation.sh",
    "step10h-frigate-camera-validation.sh",
    "step10i-frigate-tpu-validation.sh",
    "step10j-frigate-gpu-validation.sh",
    "step10p-frigate-event-recording-validation.sh",
    "step10n-frigate-homeassistant-smoketest.sh",
    "step13b-frigate-media-retention-validation.sh",
)
BACKUP = "/var/lib/frigate-upgrades/20261118-123456123456789-0.17.2-to-0.18.2"


class Step18CTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for folder in ("scripts", "lib", "config", "bin"):
            (self.root / folder).mkdir()
        shutil.copy(REPO / "scripts/step18c-frigate-post-upgrade-validation.sh", self.root / "scripts")
        shutil.copy(REPO / "lib/common.sh", self.root / "lib")
        shutil.copy(REPO / "lib/logging.sh", self.root / "lib")
        shutil.copy(REPO / "config/defaults.conf", self.root / "config")
        self.validator_log = self.root / "validators.log"
        for validator in VALIDATORS:
            path = self.root / "scripts" / validator
            path.write_text(
                '#!/bin/bash\nprintf "%s\\n" "$(basename "$0")" >> "$VALIDATOR_LOG"\n'
                '[[ "${FAIL_VALIDATOR:-}" != "$(basename "$0")" ]]\n')
            path.chmod(0o755)
        pct = self.root / "bin/pct"
        pct.write_text(r'''#!/bin/bash
printf '%s\n' "$*" >> "$PCT_LOG"
case "$1" in
 status)
   [[ "$STATUS_FAIL" != 1 ]] || { echo 'permission denied to Proxmox IPC' >&2; exit 1; }
   [[ "$STATUS_STOPPED" != 1 ]] && echo 'status: running' || echo 'status: stopped' ;;
 exec)
   shift 3
   case "$1" in
     docker)
       shift
       [[ "$1" == inspect ]] || exit 2
       if [[ "$*" == *'.Config.Image'* ]]; then echo "${ACTUAL_IMAGE:-ghcr.io/blakeblackshear/frigate:0.18.2}"
       elif [[ "$*" == *'.State.Health.Status'* ]]; then echo "${HEALTH:-healthy}"
       else exit 2; fi ;;
     curl) echo "${API_VERSION:-0.18.2-cfa08c5}" ;;
     test) [[ "$TEST_FAIL" != 1 ]] ;;
     bash) [[ "$BACKUP_CHECK_FAIL" != 1 ]] ;;
     grep)
       [[ "$BACKUP_METADATA_FAIL" != 1 ]] || exit 1
       case "$*" in
         *"TARGET_VERSION='0.18.2'"*|*"TARGET_IMAGE='ghcr.io/blakeblackshear/frigate:0.18.2'"*) exit 0 ;;
         *) exit 1 ;;
       esac ;;
     *) echo "unexpected guest operation: $*" >&2; exit 9 ;;
   esac ;;
 *) exit 2 ;;
esac
''')
        pct.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.root / "bin"}:' + os.environ["PATH"],
                        PCT_LOG=str(self.root / "pct.log"),
                        VALIDATOR_LOG=str(self.validator_log),
                        LOG_FILE=str(self.root / "operation.log"),
                        STATUS_FAIL="0", STATUS_STOPPED="0", TEST_FAIL="0",
                        BACKUP_CHECK_FAIL="0", BACKUP_METADATA_FAIL="0")

    def run_script(self, *args, **changes):
        return subprocess.run(["bash", str(self.root / "scripts/step18c-frigate-post-upgrade-validation.sh"), *args],
                              env=dict(self.env, **changes), text=True, capture_output=True)

    def test_baseline_runs_every_validator_and_passes(self):
        result = self.run_script("--expected-version", "0.18.2", "--baseline-test")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no upgrade is being accepted", result.stdout)
        self.assertEqual(self.validator_log.read_text().splitlines(), list(VALIDATORS))
        self.assertNotIn("sha256sum", (self.root / "pct.log").read_text())

    def test_failed_track_is_reported_and_remaining_tracks_still_run(self):
        result = self.run_script("--expected-version", "0.18.2", "--baseline-test",
                                 FAIL_VALIDATOR=VALIDATORS[1])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Post-upgrade validation failed", result.stdout)
        self.assertEqual(self.validator_log.read_text().splitlines(), list(VALIDATORS))

    def test_normal_mode_checks_managed_backup_and_target_metadata(self):
        result = self.run_script("--expected-version", "0.18.2", "--backup-dir", BACKUP)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.root / "pct.log").read_text()
        self.assertIn("sha256sum -c SHA256SUMS", calls)
        self.assertIn("TARGET_VERSION='0.18.2'", calls)
        self.assertIn("TARGET_IMAGE='ghcr.io/blakeblackshear/frigate:0.18.2'", calls)

    def test_invalid_args_and_status_errors_abort_before_validation(self):
        cases = (
            (("--expected-version", "0.18.2", "--expected-version", "0.18.3", "--baseline-test"), {}, "only be provided once"),
            (("--expected-version", "0.18.2", "--backup-dir", BACKUP, "--backup-dir", BACKUP, ), {}, "only be provided once"),
            (("--expected-version", "0.18.2", "--backup-dir", "/var/lib/frigate-upgrades/../../tmp/evil"), {}, "managed Step 18B"),
            (("--expected-version", "0.18.2", "--baseline-test", "--backup-dir", BACKUP), {}, "Do not combine"),
            (("--expected-version", "0.18.2", "--baseline-test"), {"STATUS_FAIL": "1"}, "Could not query CT 200 status"),
            (("--expected-version", "0.18.2", "--baseline-test"), {"STATUS_STOPPED": "1"}, "CT 200 is not running"),
        )
        for args, changes, message in cases:
            with self.subTest(args=args, changes=changes):
                self.validator_log.unlink(missing_ok=True)
                result = self.run_script(*args, **changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stdout + result.stderr)
                self.assertFalse(self.validator_log.exists())

    def test_wrong_version_or_bad_backup_never_runs_validators(self):
        cases = (
            ({"ACTUAL_IMAGE": "ghcr.io/blakeblackshear/frigate:stable"}, "Expected image"),
            ({"API_VERSION": "0.18.1"}, "Expected API"),
            ({"HEALTH": "unhealthy"}, "not healthy"),
            ({"BACKUP_CHECK_FAIL": "1"}, "Backup integrity"),
            ({"BACKUP_METADATA_FAIL": "1"}, "metadata does not match"),
        )
        for changes, message in cases:
            with self.subTest(changes=changes):
                self.validator_log.unlink(missing_ok=True)
                result = self.run_script("--expected-version", "0.18.2", "--backup-dir", BACKUP, **changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stdout + result.stderr)
                self.assertFalse(self.validator_log.exists())


if __name__ == "__main__":
    unittest.main()
