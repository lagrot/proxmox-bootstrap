#!/usr/bin/env python3
"""Test the Step 18B Compose helper and dry-run boundary without Proxmox."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
OLD = "ghcr.io/blakeblackshear/frigate:0.17.2"
NEW = "ghcr.io/blakeblackshear/frigate:0.18.2"


class ComposeHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.compose = self.root / "docker-compose.yml"
        self.compose.write_text(f"services:\n  frigate:\n    image: {OLD}\n")
        self.helper = REPO / "lib/frigate-upgrade-compose.py"

    def run_helper(self, *args):
        return subprocess.run(["python3", str(self.helper), str(self.compose), *args],
                              text=True, capture_output=True)

    def test_exact_check_and_atomic_replace_preserve_mode(self):
        self.compose.chmod(0o640)
        result = self.run_helper("--check-image", OLD)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MATCH", result.stdout)
        result = self.run_helper("--replace-image", OLD, NEW)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(NEW, self.compose.read_text())
        self.assertEqual(self.compose.stat().st_mode & 0o777, 0o640)
        self.assertEqual(list(self.root.glob(".docker-compose.yml.*")), [])

    def test_rejects_duplicate_or_unexpected_image_without_changing_file(self):
        original = self.compose.read_bytes()
        self.compose.write_bytes(original + f"  other:\n    image: {OLD}\n".encode())
        before = self.compose.read_bytes()
        for args in (("--check-image", OLD), ("--replace-image", OLD, NEW)):
            result = self.run_helper(*args)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.compose.read_bytes(), before)

    def test_refuses_symlink(self):
        target = self.root / "target.yml"
        target.write_text(f"services:\n  frigate:\n    image: {OLD}\n")
        self.compose.unlink()
        self.compose.symlink_to(target)
        result = self.run_helper("--replace-image", OLD, NEW)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text().count(OLD), 1)


class DryRunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for folder in ("scripts", "lib", "config", "bin", "app", "config-dir"):
            (self.root / folder).mkdir()
        shutil.copy(REPO / "scripts/step18b-frigate-upgrade.sh", self.root / "scripts")
        shutil.copy(REPO / "lib/frigate-upgrade-compose.py", self.root / "lib")
        shutil.copy(REPO / "lib/common.sh", self.root / "lib")
        shutil.copy(REPO / "lib/logging.sh", self.root / "lib")
        defaults = (REPO / "config/defaults.conf").read_text()
        defaults = defaults.replace('FRIGATE_APP_DIR="/opt/frigate"', f'FRIGATE_APP_DIR="{self.root / "app"}"')
        defaults = defaults.replace('FRIGATE_CONFIG_DIR="/opt/frigate/config"', f'FRIGATE_CONFIG_DIR="{self.root / "config-dir"}"')
        (self.root / "config/defaults.conf").write_text(defaults)
        (self.root / "app/docker-compose.yml").write_text(
            f"services:\n  frigate:\n    image: {OLD}\n")
        pct = self.root / "bin/pct"
        pct.write_text(r'''#!/bin/bash
printf '%s\n' "$*" >> "$PCT_LOG"
case "$1" in
 status)
   [[ "$STATUS_FAIL" != 1 ]] || { echo 'permission denied' >&2; exit 1; }
   [[ "$STATUS_STOPPED" != 1 ]] && echo 'status: running' || echo 'status: stopped' ;;
 exec)
   shift 3
   case "$1" in
     docker)
       shift
       case "$1" in
         inspect)
           if [[ "$*" == *'.Config.Image'* ]]; then echo "${CURRENT_IMAGE:-ghcr.io/blakeblackshear/frigate:0.17.2}"
           elif [[ "$*" == *'.State.Health.Status'* ]]; then echo healthy
           else exit 2; fi ;;
         *) echo "unexpected docker operation: $*" >&2; exit 9 ;;
       esac ;;
     curl) echo 0.17.2 ;;
     python3) exec "$@" ;;
     *) echo "unexpected guest operation: $*" >&2; exit 9 ;;
   esac ;;
 *) exit 2 ;;
esac
''')
        pct.chmod(0o755)
        preflight = self.root / "scripts/step18a-frigate-upgrade-preflight.sh"
        preflight.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$PREFLIGHT_LOG"\n')
        preflight.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.root / "bin"}:' + os.environ["PATH"],
                        PCT_LOG=str(self.root / "pct.log"),
                        PREFLIGHT_LOG=str(self.root / "preflight.log"),
                        LOG_FILE=str(self.root / "operation.log"),
                        STATUS_FAIL="0", STATUS_STOPPED="0")

    def run_script(self, *args):
        return subprocess.run(["bash", str(self.root / "scripts/step18b-frigate-upgrade.sh"), *args],
                              env=self.env, text=True, capture_output=True)

    def test_dry_run_never_pulls_stops_or_changes_compose(self):
        compose = self.root / "app/docker-compose.yml"
        before = compose.read_bytes()
        result = self.run_script("--target", "0.18.2", "--release-notes-reviewed", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("target image must already be local", result.stdout)
        self.assertEqual(compose.read_bytes(), before)
        calls = (self.root / "pct.log").read_text()
        self.assertNotIn("pull", calls)
        self.assertNotIn("stop", calls)
        self.assertNotIn(" up ", calls)
        self.assertIn("--skip-pull", (self.root / "preflight.log").read_text())

    def test_duplicate_target_and_missing_review_stop_before_proxmox(self):
        for args in (("--target", "0.18.2", "--target", "0.18.3", "--release-notes-reviewed", "--dry-run"),
                     ("--target", "0.18.2", "--dry-run")):
            (self.root / "pct.log").unlink(missing_ok=True)
            result = self.run_script(*args)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.root / "pct.log").exists())

    def test_proxmox_preflight_and_compose_failures_stop_before_mutation(self):
        cases = (
            ({"STATUS_FAIL": "1"}, "Could not query CT 200 status"),
            ({"STATUS_STOPPED": "1"}, "CT 200 is not running"),
            ({"PREFLIGHT_FAIL": "1"}, "preflight"),
            ({"CURRENT_IMAGE": "ghcr.io/blakeblackshear/frigate:stable"}, "not the exact official"),
        )
        preflight = self.root / "scripts/step18a-frigate-upgrade-preflight.sh"
        preflight.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$PREFLIGHT_LOG"\n[[ "$PREFLIGHT_FAIL" != 1 ]]\n')
        preflight.chmod(0o755)
        for changes, message in cases:
            with self.subTest(changes=changes):
                (self.root / "pct.log").unlink(missing_ok=True)
                (self.root / "preflight.log").unlink(missing_ok=True)
                result = subprocess.run(
                    ["bash", str(self.root / "scripts/step18b-frigate-upgrade.sh"),
                     "--target", "0.18.2", "--release-notes-reviewed", "--dry-run"],
                    env=dict(self.env, **changes), text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(message.lower(), (result.stdout + result.stderr).lower())
                calls = (self.root / "pct.log").read_text() if (self.root / "pct.log").exists() else ""
                self.assertNotIn("pull", calls)
                self.assertNotIn("stop", calls)
                self.assertNotIn(" up ", calls)

        compose = self.root / "app/docker-compose.yml"
        compose.write_text(f"services:\n  frigate:\n    image: {NEW}\n")
        result = subprocess.run(
            ["bash", str(self.root / "scripts/step18b-frigate-upgrade.sh"),
             "--target", "0.18.2", "--release-notes-reviewed", "--dry-run"],
            env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Compose must contain exactly one image entry", result.stdout)


if __name__ == "__main__":
    unittest.main()
