#!/usr/bin/env python3
"""Exercise Step 10G rendering and transaction safeguards without Proxmox."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("frigate_camera_config",
                                              REPO / "lib/frigate-camera-config.py")
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


def settings(**changes):
    result = {
        "name": "tplink_c200_1", "ip": "192.168.8.107", "username": "camera user",
        "password": "pass:/?word", "rtsp_port": "554", "record_path": "/stream1",
        "detect_path": "/stream2", "width": "640", "height": "360", "fps": "5",
        "onvif_port": "2020",
    }
    result.update(changes)
    return result


class CameraConfigRenderTests(unittest.TestCase):
    def test_add_replace_and_idempotence_preserve_other_camera(self):
        original = 'mqtt:\n  enabled: true\ncameras:\n  other_cam:\n    enabled: true\n'
        updated = helper.render(original, settings())
        self.assertIn("  other_cam:\n    enabled: true", updated)
        self.assertIn("  tplink_c200_1:", updated)
        self.assertIn("rtsp://camera%20user:pass%3A%2F%3Fword@192.168.8.107:554/stream1", updated)
        self.assertIn('password: "pass:/?word"', updated)
        self.assertEqual(helper.render(updated, settings()), updated)
        replaced = helper.render(updated, settings(ip="192.168.8.108"))
        self.assertEqual(replaced.count("  tplink_c200_1:"), 1)
        self.assertIn("192.168.8.108", replaced)
        self.assertIn("  other_cam:\n    enabled: true", replaced)

    def test_adds_missing_or_inline_camera_section(self):
        self.assertIn("cameras:\n  tplink_c200_1:", helper.render("version: 0.16\n", settings()))
        inline = helper.render("cameras: {}\n", settings())
        self.assertEqual(inline.count("cameras:"), 1)
        self.assertIn("  tplink_c200_1:", inline)

    def test_rejects_ambiguous_camera_sections(self):
        with self.assertRaisesRegex(ValueError, "multiple top-level cameras"):
            helper.render("cameras: {}\ncameras: {}\n", settings())
        duplicate = ("cameras:\n  tplink_c200_1:\n    enabled: true\n"
                     "  tplink_c200_1:\n    enabled: false\n")
        with self.assertRaisesRegex(ValueError, "multiple camera blocks"):
            helper.render(duplicate, settings())

    def test_rejects_invalid_inputs_and_control_characters(self):
        for invalid in (
            {"name": "bad-name"}, {"ip": "example.invalid"}, {"ip": "203.0.113.4"},
            {"rtsp_port": "65536"}, {"onvif_port": "0"}, {"width": "0"},
            {"fps": "2;touch /tmp/x"}, {"record_path": "/stream1/../../etc"},
            {"detect_path": "/stream2?user=x"}, {"password": "line\nbreak"},
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                helper.render("cameras: {}\n", settings(**invalid))

    def test_atomic_write_preserves_metadata_and_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.yml"
            path.write_text("cameras: {}\n")
            path.chmod(0o640)
            helper.atomic_write(path, "cameras:\n  camera:\n    enabled: true\n")
            self.assertEqual(path.read_text(), "cameras:\n  camera:\n    enabled: true\n")
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            self.assertEqual(list(Path(directory).iterdir()), [path])
            link = Path(directory) / "link.yml"
            link.symlink_to(path)
            payload = b"\0".join(value.encode() for value in settings().values()) + b"\0"
            result = subprocess.run(["python3", str(REPO / "lib/frigate-camera-config.py"), str(link)],
                                    input=payload, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"symbolic link", result.stderr)


class CameraConfigScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("scripts", "config", "lib", "bin", "app"):
            (self.root / name).mkdir()
        for name in ("common.sh", "logging.sh"):
            shutil.copy(REPO / "lib" / name, self.root / "lib" / name)
        shutil.copy(REPO / "lib/frigate-camera-config.py", self.root / "lib/frigate-camera-config.py")
        defaults = (REPO / "config/defaults.conf").read_text()
        defaults = defaults.replace('FRIGATE_APP_DIR="/opt/frigate"',
                                    f'FRIGATE_APP_DIR="{self.root / "app"}"')
        defaults = defaults.replace('FRIGATE_CONFIG_FILE="/opt/frigate/config/config.yml"',
                                    f'FRIGATE_CONFIG_FILE="{self.root / "guest-config.yml"}"')
        (self.root / "config/defaults.conf").write_text(defaults)
        (self.root / "config/local.conf").write_text(
            'TAPO_C200_IP="192.168.8.107"\nTAPO_C200_USERNAME="test-user"\n'
            'TAPO_C200_PASSWORD="test-camera-password"\n')
        shutil.copy(REPO / "scripts/step10g-frigate-tapo-camera-config.sh",
                    self.root / "scripts/step10g-frigate-tapo-camera-config.sh")
        self.config = self.root / "guest-config.yml"
        self.original = 'version: "0.16"\ncameras:\n  other_cam:\n    enabled: true\n'
        self.config.write_text(self.original)
        fake = r'''#!/bin/bash
case "$1" in
  config) exit 0 ;;
  status)
    [[ "$STATUS_FAIL" != 1 ]] || { echo 'permission denied to Proxmox IPC' >&2; exit 1; }
    [[ "$STATUS_STOPPED" != 1 ]] && echo 'status: running' || echo 'status: stopped' ;;
  exec)
    shift 3
    case "$1" in
      test)
        case "$2" in
          -f) [[ -f "$3" ]] ;;
          !) [[ "$3" == -e && ! -e "$4" ]] ;;
          *) exit 1 ;;
        esac ;;
      cp) shift; cp "$@" ;;
      python3) shift; /usr/bin/python3 "$@" ;;
      bash)
        [[ "$COMPOSE_FAIL_ALWAYS" != 1 ]] || exit 1
        if [[ "$COMPOSE_FAIL_AFTER" == 1 ]]; then
          count=0; [[ ! -f "$COMPOSE_COUNT" ]] || count=$(cat "$COMPOSE_COUNT")
          count=$((count + 1)); echo "$count" > "$COMPOSE_COUNT"
          [[ "$count" -lt 2 ]] || exit 1
        fi
        exit 0 ;;
      *) exit 1 ;;
    esac ;;
esac
'''
        pct = self.root / "bin/pct"
        pct.write_text(fake)
        pct.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / "bin") + ":" + os.environ["PATH"],
                        COMPOSE_FAIL_AFTER="0", COMPOSE_FAIL_ALWAYS="0",
                        STATUS_FAIL="0", STATUS_STOPPED="0",
                        COMPOSE_COUNT=str(self.root / "compose-count"),
                        LOG_FILE=str(self.root / "operation.log"))

    def run_script(self, *args, **extra):
        return subprocess.run(["bash", str(self.root / "scripts/step10g-frigate-tapo-camera-config.sh"), *args],
                              env=dict(self.env, **extra), text=True, capture_output=True)

    def backups(self):
        return list(self.root.glob("guest-config.yml.bak-*"))

    def test_help_unknown_option_and_missing_inputs_are_safe(self):
        help_result = self.run_script("--help")
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("--dry-run", help_result.stdout)
        bad = self.run_script("--unexpected")
        self.assertNotEqual(bad.returncode, 0)
        missing = self.run_script(TAPO_CAMERA_PROFILE="c320ws")
        self.assertNotEqual(missing.returncode, 0)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(self.backups(), [])

    def test_dry_run_has_no_writes_backups_or_secret_output(self):
        result = self.run_script("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("No backup, configuration write, or service restart", result.stdout)
        self.assertNotIn("test-camera-password", result.stdout + result.stderr)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(self.backups(), [])
        self.assertFalse((self.root / "operation.log").exists())

    def test_existing_shared_detect_fps_override_is_preserved(self):
        result = self.run_script("--dry-run", TAPO_CAMERA_DETECT_FPS="3")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("640x360@3 FPS", result.stdout)
        self.assertEqual(self.config.read_text(), self.original)

    def test_apply_is_atomic_backed_up_and_idempotent(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("updated and validated successfully", result.stdout)
        self.assertNotIn("test-camera-password", result.stdout + result.stderr)
        self.assertIn("tplink_c200_1", self.config.read_text())
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(self.backups()[0].read_text(), self.original)
        second = self.run_script()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("no backup or write is needed", second.stdout)
        self.assertEqual(len(self.backups()), 1)

    def test_status_error_and_post_write_validation_failure_are_safe(self):
        status_error = self.run_script(STATUS_FAIL="1")
        self.assertNotEqual(status_error.returncode, 0)
        self.assertIn("Could not query status", status_error.stdout)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(self.backups(), [])
        failed = self.run_script(COMPOSE_FAIL_AFTER="1")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("rolled back", failed.stdout)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(len(self.backups()), 1)

    def test_invalid_compose_preflight_prevents_backup_or_write(self):
        result = self.run_script(COMPOSE_FAIL_ALWAYS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("current configuration is invalid", result.stdout)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(self.backups(), [])


if __name__ == "__main__":
    unittest.main()
