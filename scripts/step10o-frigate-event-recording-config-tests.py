#!/usr/bin/env python3
"""Test Step 10O config rendering and safe apply behavior without Proxmox."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "frigate_event_recording_config", REPO / "lib/frigate-event-recording-config.py")
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


class RenderTests(unittest.TestCase):
    def test_inserts_or_replaces_managed_record_section_and_is_idempotent(self):
        base = 'mqtt:\n  enabled: true\ncameras: {}\n'
        result = helper.render(base, "10", "5", "5")
        self.assertIn("  continuous:\n    days: 0", result)
        self.assertIn("      days: 10", result)
        self.assertIn("mqtt:\n  enabled: true", result)
        self.assertEqual(helper.render(result, "10", "5", "5"), result)
        changed = helper.render(result, "7", "3", "4")
        self.assertIn("      days: 7", changed)
        self.assertIn("    pre_capture: 3", changed)
        self.assertIn("    post_capture: 4", changed)

    def test_refuses_duplicate_or_unmanaged_record_settings(self):
        with self.assertRaisesRegex(ValueError, "multiple top-level"):
            helper.render("record:\n  enabled: true\nrecord:\n", "10", "5", "5")
        with self.assertRaisesRegex(ValueError, "unmanaged keys"):
            helper.render("record:\n  retain:\n    days: 2\n", "10", "5", "5")
        with self.assertRaisesRegex(ValueError, "unmanaged keys"):
            helper.render("record:\n  enabled: true\n    bad: true\n", "10", "5", "5")

    def test_atomic_write_preserves_mode_and_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.yml"
            path.write_text("version: 0.17\n")
            path.chmod(0o640)
            helper.atomic_write(path, "record:\n  enabled: true\n")
            self.assertEqual(path.read_text(), "record:\n  enabled: true\n")
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            backup = Path(directory) / "backup.yml"
            backup.write_text("version: 0.17\n")
            backup.chmod(0o600)
            restored = subprocess.run(["python3", str(REPO / "lib/frigate-event-recording-config.py"),
                                       str(path), "--restore", str(backup)], capture_output=True, text=True)
            self.assertEqual(restored.returncode, 0, restored.stderr)
            self.assertEqual(path.read_text(), "version: 0.17\n")
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            self.assertEqual([p.name for p in Path(directory).iterdir()], ["config.yml", "backup.yml"])
            link = Path(directory) / "link.yml"
            link.symlink_to(path)
            result = subprocess.run(["python3", str(REPO / "lib/frigate-event-recording-config.py"),
                                     str(link), "10", "5", "5"], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symbolic link", result.stderr)


class OperatorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for folder in ("scripts", "lib", "config", "bin", "app"):
            (self.root / folder).mkdir()
        shutil.copy(REPO / "scripts/step10o-frigate-event-recording-config.sh", self.root / "scripts")
        shutil.copy(REPO / "lib/frigate-event-recording-config.py", self.root / "lib")
        shutil.copy(REPO / "lib/common.sh", self.root / "lib")
        shutil.copy(REPO / "lib/logging.sh", self.root / "lib")
        defaults = (REPO / "config/defaults.conf").read_text()
        defaults = defaults.replace('FRIGATE_APP_DIR="/opt/frigate"', f'FRIGATE_APP_DIR="{self.root / "app"}"')
        defaults = defaults.replace('FRIGATE_CONFIG_FILE="/opt/frigate/config/config.yml"',
                                    f'FRIGATE_CONFIG_FILE="{self.root / "config.yml"}"')
        (self.root / "config/defaults.conf").write_text(defaults)
        self.config = self.root / "config.yml"
        self.original = "mqtt:\n  enabled: true\ncameras: {}\n"
        self.config.write_text(self.original)
        pct = self.root / "bin/pct"
        pct.write_text(r'''#!/bin/bash
case "$1" in
 status) echo 'status: running' ;;
 exec)
   shift 3
   case "$1" in
     test) [[ "$2" == -f ]] && [[ -f "$3" ]] || [[ "$2" == '!' && "$3" == -e && ! -e "$4" ]] ;;
     cp) shift; cp "$@" || { echo "fake cp failed: $*" >&2; exit 1; } ;;
     python3) shift; /usr/bin/python3 "$@" ;;
     bash)
       [[ "$COMPOSE_FAIL" != 1 ]] || exit 1
       if [[ "$COMPOSE_FAIL_AFTER" == 1 ]]; then
         count=0; [[ ! -f "$COMPOSE_COUNT" ]] || count=$(cat "$COMPOSE_COUNT")
         count=$((count + 1)); echo "$count" > "$COMPOSE_COUNT"
         [[ "$count" -lt 2 ]] || exit 1
       fi ;;
     *) exit 2 ;;
   esac ;;
 *) exit 2 ;;
esac
''')
        pct.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.root / "bin"}:' + os.environ["PATH"],
                        LOG_FILE=str(self.root / "operation.log"), COMPOSE_FAIL="0",
                        COMPOSE_FAIL_AFTER="0", COMPOSE_COUNT=str(self.root / "compose-count"))

    def run_script(self, *args, **env):
        return subprocess.run(["bash", str(self.root / "scripts/step10o-frigate-event-recording-config.sh"),
                               *args], env=dict(self.env, **env), text=True, capture_output=True)

    def backups(self):
        return list(self.root.glob("config.yml.bak-event-recording-*"))

    def test_help_and_invalid_arguments_do_not_touch_config(self):
        help_result = self.run_script("--help")
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("--dry-run", help_result.stdout)
        invalid = self.run_script("--bad")
        self.assertEqual(invalid.returncode, 2)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(self.backups(), [])

    def test_dry_run_has_no_writes_or_backup(self):
        result = self.run_script("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("No backup, configuration write, or service restart", result.stdout)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(self.backups(), [])
        self.assertFalse((self.root / "operation.log").exists())

    def test_apply_backs_up_atomically_and_is_idempotent(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("updated and Docker Compose validation passed", result.stdout)
        self.assertIn("days: 10", self.config.read_text())
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(self.backups()[0].read_text(), self.original)
        self.assertEqual(self.backups()[0].stat().st_mode & 0o777, 0o600)
        second = self.run_script()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("no backup or write is needed", second.stdout)
        self.assertEqual(len(self.backups()), 1)

    def test_compose_preflight_and_unknown_record_key_fail_without_writes(self):
        compose = self.run_script(COMPOSE_FAIL="1")
        self.assertNotEqual(compose.returncode, 0)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(self.backups(), [])
        self.config.write_text("record:\n  retain:\n    mode: active_objects\n")
        unknown_original = self.config.read_text()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.config.read_text(), unknown_original)
        self.assertEqual(self.backups(), [])

    def test_post_write_compose_failure_restores_backup(self):
        result = self.run_script(COMPOSE_FAIL_AFTER="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restored from", result.stdout + result.stderr)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(self.backups()[0].read_text(), self.original)


if __name__ == "__main__":
    unittest.main()
