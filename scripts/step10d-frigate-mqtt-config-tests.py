#!/usr/bin/env python3
"""Exercise Frigate MQTT config editing and Step 10D transaction safeguards."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("frigate_mqtt_config", REPO / "lib/frigate-mqtt-config.py")
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


class ConfigEditorTests(unittest.TestCase):
    def test_adds_section_and_is_idempotent(self):
        original = "cameras:\n  front: {}\n"
        updated = helper.render(original, "192.0.2.10", "1883")
        self.assertEqual(updated, "mqtt:\n  enabled: true\n  host: 192.0.2.10\n  port: 1883\n\ncameras:\n  front: {}\n")
        self.assertEqual(helper.render(updated, "192.0.2.10", "1883"), updated)

    def test_preserves_credentials_other_settings_comments_and_format(self):
        original = (
            "mqtt:\n"
            "  enabled: false # currently disabled\n"
            "  host: old-broker\n"
            "  port: 1884\n"
            "  user: frigate\n"
            "  password: secret-placeholder\n"
            "  client_id: frigate\n"
            "  tls:\n"
            "    enabled: false\n"
            "cameras: {}\n"
        )
        updated = helper.render(original, "192.0.2.10", "1883")
        for preserved in ("  user: frigate", "  password: secret-placeholder",
                          "  client_id: frigate", "  tls:\n    enabled: false"):
            self.assertIn(preserved, updated)
        self.assertIn("  enabled: true # currently disabled", updated)
        self.assertIn("  host: 192.0.2.10", updated)
        self.assertIn("  port: 1883", updated)
        self.assertEqual(helper.render(updated, "192.0.2.10", "1883"), updated)

    def test_ambiguous_yaml_and_invalid_target_are_rejected(self):
        with self.assertRaises(ValueError):
            helper.render("mqtt:\n  enabled: true\nmqtt:\n  enabled: false\n", "192.0.2.10", "1883")
        with self.assertRaises(ValueError):
            helper.render("mqtt:\n  host: a\n  host: b\n", "192.0.2.10", "1883")
        for host, port in (("example.invalid", "1883"), ("192.0.2.10", "0"),
                           ("192.0.2.10", "65536")):
            with self.subTest(host=host, port=port), self.assertRaises(ValueError):
                helper.render("mqtt: {}\n", host, port)

    def test_empty_inline_section_is_converted_instead_of_duplicated(self):
        updated = helper.render("mqtt: {} # placeholder\ncameras: {}\n", "192.0.2.10", "1883")
        self.assertEqual(updated.count("mqtt:"), 1)
        self.assertIn("mqtt: # placeholder", updated)
        self.assertIn("  host: 192.0.2.10", updated)

    def test_atomic_write_preserves_owner_mode_and_removes_temp(self):
        with tempfile.TemporaryDirectory() as temporary_dir:
            path = Path(temporary_dir) / "config.yml"
            path.write_text("mqtt: {}\n")
            path.chmod(0o640)
            helper.atomic_write(path, "mqtt:\n  enabled: true\n")
            self.assertEqual(path.read_text(), "mqtt:\n  enabled: true\n")
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            self.assertEqual(list(Path(temporary_dir).iterdir()), [path])

    def test_config_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_dir:
            target = Path(temporary_dir) / "real.yml"
            target.write_text("mqtt: {}\n")
            link = Path(temporary_dir) / "config.yml"
            link.symlink_to(target)
            result = subprocess.run(["python3", str(REPO / "lib/frigate-mqtt-config.py"),
                                     str(link), "192.0.2.10", "1883"],
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must not be a symbolic link", result.stderr)
            self.assertEqual(target.read_text(), "mqtt: {}\n")


class ScriptTransactionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("scripts", "config", "lib", "bin", "backups"):
            (self.root / name).mkdir()
        for name in ("common.sh", "logging.sh"):
            shutil.copy(REPO / "lib" / name, self.root / "lib" / name)
        shutil.copy(REPO / "lib/frigate-mqtt-config.py", self.root / "lib/frigate-mqtt-config.py")
        defaults = (REPO / "config/defaults.conf").read_text()
        defaults = defaults.replace('FRIGATE_APP_DIR="/opt/frigate"',
                                    f'FRIGATE_APP_DIR="{self.root / "app"}"')
        defaults = defaults.replace('FRIGATE_CONFIG_FILE="/opt/frigate/config/config.yml"',
                                    'FRIGATE_CONFIG_FILE="/opt/frigate/config/config.yml"')
        (self.root / "config/defaults.conf").write_text(defaults)
        shutil.copy(REPO / "scripts/step10d-frigate-mqtt-config.sh",
                    self.root / "scripts/step10d-frigate-mqtt-config.sh")
        self.config = self.root / "frigate-config.yml"
        self.config.write_text("mqtt:\n  enabled: true\n  host: 192.0.2.9\n  port: 1883\n  user: frigate\n  password: secret-placeholder\ncameras: {}\n")
        fake = r'''#!/bin/bash
case "$1" in
  config) echo 'hostname: test-ct'; exit 0 ;;
  status)
    [[ "${STATUS_FAIL_CT:-}" != "$2" ]] || exit 1
    printf 'status: %s\n' "${CT_STATUS:-running}"
    exit 0 ;;
  exec)
    shift 3
    case "$1" in
      ip) echo '2: eth0 inet 192.0.2.10/24 brd 192.0.2.255'; exit 0 ;;
      test) [[ -f "$TEST_CONFIG" ]] ;;
      docker) exit 0 ;;
      python3)
        if [[ "$2" == "-" ]]; then
          if [[ "$6" == "--check" ]]; then
            python3 - "$TEST_CONFIG" "$4" "$5" --check
          else
            python3 - "$TEST_CONFIG" "$4" "$5"
          fi
          exit $?
        fi ;;
      mktemp)
        backup="$TEST_BACKUPS/$(basename "$2")"
        : > "$backup"
        chmod 600 "$backup"
        echo "$backup" ;;
      cp)
        source="$2"; target="$3"
        [[ "$source" != /opt/frigate/config/config.yml ]] || source="$TEST_CONFIG"
        [[ "$target" != /opt/frigate/config/config.yml ]] || target="$TEST_CONFIG"
        cp "$source" "$target" ;;
      chmod) chmod "$2" "$3" ;;
      grep)
        args=("${@:2}")
        [[ "${args[-1]}" != /opt/frigate/config/config.yml ]] || args[-1]="$TEST_CONFIG"
        grep "${args[@]}" ;;
      bash)
        [[ "$COMPOSE_FAIL" != 1 ]] ;;
      rm) rm -f "$2" ;;
      *) exit 0 ;;
    esac ;;
esac
'''
        for name in ("pct",):
            path = self.root / "bin" / name
            path.write_text(fake)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / "bin") + ":" + os.environ["PATH"],
                        TEST_CONFIG=str(self.config), TEST_BACKUPS=str(self.root / "backups"),
                        COMPOSE_FAIL="0", STATUS_FAIL_CT="", CT_STATUS="running",
                        LOG_FILE=str(self.root / "operation.log"))

    def run_script(self, *args, **extra):
        return subprocess.run(["bash", str(self.root / "scripts/step10d-frigate-mqtt-config.sh"), *args],
                              env=dict(self.env, **extra), text=True, capture_output=True)

    def test_dry_run_and_invalid_arguments_do_not_write(self):
        original = self.config.read_text()
        result = self.run_script("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("No backup or configuration write was made", result.stdout)
        self.assertEqual(self.config.read_text(), original)
        self.assertEqual(list((self.root / "backups").iterdir()), [])
        self.assertFalse((self.root / "operation.log").exists())
        bad = self.run_script("--unknown")
        self.assertNotEqual(bad.returncode, 0)
        self.assertEqual(self.config.read_text(), original)

    def test_apply_preserves_credentials_and_second_run_is_noop(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        updated = self.config.read_text()
        self.assertIn("  user: frigate", updated)
        self.assertIn("  password: secret-placeholder", updated)
        self.assertIn("  host: 192.0.2.10", updated)
        self.assertNotIn("secret-placeholder", result.stdout)
        backups = list((self.root / "backups").iterdir())
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
        second = self.run_script()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("no backup or write is needed", second.stdout)
        self.assertEqual(len(list((self.root / "backups").iterdir())), 1)

    def test_compose_failure_restores_original_config(self):
        original = self.config.read_text()
        result = self.run_script(COMPOSE_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("config was rolled back", result.stdout)
        self.assertEqual(self.config.read_text(), original)

    def test_bad_port_is_rejected_before_guest_changes(self):
        defaults = self.root / "config/defaults.conf"
        defaults.write_text(defaults.read_text().replace('MQTT_PORT="1883"', 'MQTT_PORT="70000"'))
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MQTT_PORT must be an integer", result.stdout)
        self.assertEqual(self.config.read_text(), "mqtt:\n  enabled: true\n  host: 192.0.2.9\n  port: 1883\n  user: frigate\n  password: secret-placeholder\ncameras: {}\n")

    def test_ct_status_query_failure_and_stopped_ct_are_explicit(self):
        result = self.run_script(STATUS_FAIL_CT="210")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not determine CT 210 status", result.stdout)
        self.assertEqual(self.config.read_text().split("host: ")[1].splitlines()[0], "192.0.2.9")
        result = self.run_script(CT_STATUS="stopped")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CT 200 is not running (reported: status: stopped)", result.stdout)

    def test_duplicate_container_ids_are_rejected_before_guest_checks(self):
        defaults = self.root / "config/defaults.conf"
        defaults.write_text(defaults.read_text().replace('MQTT_CT_ID="210"', 'MQTT_CT_ID="200"'))
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must use different container IDs", result.stdout)
        self.assertNotIn("Checking CT 200...", result.stdout)
        self.assertEqual(self.config.read_text().split("host: ")[1].splitlines()[0], "192.0.2.9")


if __name__ == "__main__":
    unittest.main()
