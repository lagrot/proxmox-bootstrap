#!/usr/bin/env python3
"""Exercise Step 18A preflight paths without calling Proxmox or Docker."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for folder in ("scripts", "lib", "config", "bin", "app", "frigate-config"):
            (self.root / folder).mkdir()
        shutil.copy(REPO / "scripts/step18a-frigate-upgrade-preflight.sh", self.root / "scripts")
        shutil.copy(REPO / "lib/common.sh", self.root / "lib")
        shutil.copy(REPO / "lib/logging.sh", self.root / "lib")
        defaults = (REPO / "config/defaults.conf").read_text()
        defaults = defaults.replace('FRIGATE_APP_DIR="/opt/frigate"',
                                    f'FRIGATE_APP_DIR="{self.root / "app"}"')
        defaults = defaults.replace('FRIGATE_CONFIG_DIR="/opt/frigate/config"',
                                    f'FRIGATE_CONFIG_DIR="{self.root / "frigate-config"}"')
        (self.root / "config/defaults.conf").write_text(defaults)
        self.compose = self.root / "app/docker-compose.yml"
        self.compose.write_text('services:\n  frigate:\n    image: ghcr.io/blakeblackshear/frigate:0.17.2\n')
        self.config = self.root / "frigate-config/config.yml"
        self.config.write_text("mqtt:\n  enabled: true\n")
        self.pct_log = self.root / "pct.log"
        self.initial_validation_dirs = set(Path("/tmp").glob("frigate-upgrade-preflight.*"))
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
       case "$1" in
         inspect)
           if [[ "$*" == *'.Config.Image'* ]]; then echo 'ghcr.io/blakeblackshear/frigate:0.17.2'
           elif [[ "$*" == *'.State.Health.Status'* ]]; then [[ "$UNHEALTHY" != 1 ]] && echo healthy || echo unhealthy
           else exit 2; fi ;;
         image)
           [[ "$2" == inspect ]] || exit 2
           [[ "$TARGET_MISSING" != 1 ]] || exit 1
           if [[ "$*" == *'join .RepoTags'* ]]; then
             [[ "$TAG_MISMATCH" != 1 ]] && echo 'ghcr.io/blakeblackshear/frigate:0.18.2' || echo 'ghcr.io/blakeblackshear/frigate:other'
           fi ;;
         pull) [[ "$PULL_FAIL" != 1 ]] ;;
         run) [[ "$VALIDATE_FAIL" != 1 ]] ;;
         compose) [[ "$COMPOSE_FAIL" != 1 ]] ;;
         *) exit 2 ;;
       esac ;;
     curl) echo 0.17.2 ;;
     test) [[ "$2" == -f && -f "$3" ]] ;;
     du) shift; du -sb "$2" ;;
     df)
       n=0; [[ ! -f "$DF_COUNT" ]] || n=$(cat "$DF_COUNT"); n=$((n + 1)); echo "$n" > "$DF_COUNT"
       bytes="$FREE_BEFORE"; [[ "$n" -lt 2 ]] || bytes="$FREE_AFTER"
       printf 'Filesystem 1B-blocks Used Available Use%% Mounted on\n/dev/test 999999999 1 %s 1%% /\n' "$bytes" ;;
     mktemp) shift; [[ "$BAD_TMP" != 1 ]] && mktemp "$@" || echo "$BAD_TMP_PATH" ;;
     cp|chmod|rm) "$@" ;;
     *) exit 2 ;;
   esac ;;
 *) exit 2 ;;
esac
''')
        pct.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.root / "bin"}:' + os.environ["PATH"],
                        PCT_LOG=str(self.pct_log), LOG_FILE=str(self.root / "operation.log"),
                        STATUS_FAIL="0", STATUS_STOPPED="0", UNHEALTHY="0",
                        TARGET_MISSING="0", TAG_MISMATCH="0", PULL_FAIL="0",
                        VALIDATE_FAIL="0", COMPOSE_FAIL="0", FREE_BEFORE="10000000000",
                        FREE_AFTER="10000000000", BAD_TMP="0", BAD_TMP_PATH=str(self.root / "unexpected"),
                        DF_COUNT=str(self.root / "df-count"))

    def run_script(self, *args, **changes):
        Path(self.env["DF_COUNT"]).unlink(missing_ok=True)
        return subprocess.run(["bash", str(self.root / "scripts/step18a-frigate-upgrade-preflight.sh"),
                               *args], env=dict(self.env, **changes), text=True, capture_output=True)

    def calls(self):
        return self.pct_log.read_text().splitlines() if self.pct_log.exists() else []

    def validation_dirs(self):
        return set(Path("/tmp").glob("frigate-upgrade-preflight.*"))

    def valid_args(self, *extra):
        return ("--target", "0.18.2", "--release-notes-reviewed", *extra)

    def test_help_invalid_versions_and_missing_ack_stop_before_guest_calls(self):
        help_result = self.run_script("--help")
        self.assertEqual(help_result.returncode, 0)
        for args in ((), self.valid_args("--target", "0.18.2-rc1"),
                     ("--target", "stable", "--release-notes-reviewed"),
                     ("--target", "0.18.2", "--target", "0.18.3", "--release-notes-reviewed"),
                     ("--target", "0.18.2")):
            with self.subTest(args=args):
                self.pct_log.unlink(missing_ok=True)
                result = self.run_script(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.pct_log.exists())

    def test_skip_pull_preflight_validates_exact_image_and_cleans_temp(self):
        before = self.compose.read_bytes(), self.config.read_bytes()
        result = self.run_script(*self.valid_args("--skip-pull"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Preflight passed", result.stdout)
        self.assertIn("Using existing local target image", result.stdout)
        calls = "\n".join(self.calls())
        self.assertIn("--validate-config", calls)
        self.assertNotIn("docker pull", calls)
        self.assertNotIn("compose stop", calls)
        self.assertNotIn("compose up", calls)
        self.assertEqual((self.compose.read_bytes(), self.config.read_bytes()), before)
        self.assertEqual(self.validation_dirs(), self.initial_validation_dirs)

    def test_normal_preflight_pulls_only_the_target_and_checks_space_afterward(self):
        result = self.run_script(*self.valid_args())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = "\n".join(self.calls())
        self.assertIn("docker pull ghcr.io/blakeblackshear/frigate:0.18.2", calls)
        self.assertIn("Free space after target image preparation", result.stdout)
        self.assertNotIn("compose stop", calls)
        self.assertNotIn("compose up", calls)
        self.assertEqual(self.validation_dirs(), self.initial_validation_dirs)

    def test_distinguishes_status_failure_from_stopped_ct(self):
        failed = self.run_script(*self.valid_args("--skip-pull"), STATUS_FAIL="1")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("permission denied to Proxmox IPC", failed.stdout)
        stopped = self.run_script(*self.valid_args("--skip-pull"), STATUS_STOPPED="1")
        self.assertNotEqual(stopped.returncode, 0)
        self.assertIn("CT 200 is not running", stopped.stdout)

    def test_health_compose_capacity_pull_and_image_errors_fail_safely(self):
        cases = (
            ({"UNHEALTHY": "1"}, "not healthy"),
            ({"COMPOSE_FAIL": "1"}, "Compose file is invalid"),
            ({"FREE_BEFORE": "1000"}, "Insufficient CT space"),
            ({"FREE_AFTER": "1000"}, "Insufficient CT space after"),
            ({"PULL_FAIL": "1"}, ""),
            ({"TARGET_MISSING": "1"}, "Target image is not local"),
            ({"TAG_MISMATCH": "1"}, "exact target tag"),
            ({"VALIDATE_FAIL": "1"}, "rejected the copied Frigate config"),
        )
        for changes, message in cases:
            with self.subTest(changes=changes):
                self.pct_log.unlink(missing_ok=True)
                args = self.valid_args("--skip-pull") if "TARGET_MISSING" in changes else self.valid_args()
                result = self.run_script(*args, **changes)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                if message:
                    self.assertIn(message, result.stdout + result.stderr)
                self.assertNotIn("compose stop", "\n".join(self.calls()))
                self.assertNotIn("compose up", "\n".join(self.calls()))
                self.assertEqual(self.validation_dirs(), self.initial_validation_dirs)

    def test_unexpected_temp_path_is_never_removed(self):
        unexpected = Path(self.env["BAD_TMP_PATH"])
        unexpected.mkdir()
        marker = unexpected / "keep-me"
        marker.write_text("preserve")
        result = self.run_script(*self.valid_args("--skip-pull"), BAD_TMP="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid temporary directory", result.stdout)
        self.assertEqual(marker.read_text(), "preserve")
        self.assertNotIn("rm -rf", "\n".join(call for call in self.calls() if "rm -rf" in call))


if __name__ == "__main__":
    unittest.main()
