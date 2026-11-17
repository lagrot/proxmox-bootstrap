#!/usr/bin/env python3
"""Exercise Step 10F MQTT validation using fake Proxmox guests."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class FrigateMqttValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("scripts", "config", "lib", "bin", "remote-tmp"):
            (self.root / name).mkdir()
        for name in ("common.sh", "logging.sh"):
            shutil.copy(REPO / "lib" / name, self.root / "lib" / name)
        defaults = (REPO / "config/defaults.conf").read_text()
        (self.root / "config/defaults.conf").write_text(defaults)
        (self.root / "config/local.conf").write_text(
            'MQTT_USERNAME="test-user"\nMQTT_PASSWORD="test-password-not-secret"\n')
        script = (REPO / "scripts/step10f-frigate-mqtt-validation.sh").read_text()
        script = script.replace("/tmp/step10f-frigate-mqtt.",
                                str(self.root / "remote-tmp/step10f-frigate-mqtt."))
        (self.root / "scripts/step10f-frigate-mqtt-validation.sh").write_text(script)
        fake = r'''#!/bin/bash
case "$1" in
  status)
    [[ "$STATUS_FAIL" != 1 ]] || { echo 'permission denied to Proxmox IPC' >&2; exit 1; }
    if [[ "$STATUS_STOPPED" == 1 ]]; then echo 'status: stopped'; else echo 'status: running'; fi ;;
  exec)
    ct_id="$2"
    shift 3
    command="$*"
    if [[ "$1" == ip ]]; then
      if [[ "$ct_id" == 200 ]]; then echo '2: eth0 inet 192.0.2.20/24';
      else echo '2: eth0 inet 192.0.2.21/24'; fi
    elif [[ "$1" == grep ]]; then
      exit 0
    elif [[ "$1" == docker && "$2" == ps ]]; then
      echo frigate
    elif [[ "$1" == docker && "$2" == inspect && "$3" == --format ]]; then
      echo '2026-11-18T00:00:00Z'
    elif [[ "$1" == docker && "$2" == logs ]]; then
      [[ -z "$LOG_TEXT" ]] || printf '%s\n' "$LOG_TEXT"
    elif [[ "$1" == bash && "$2" == -c && "$3" == command\ -v* ]]; then
      exit 0
    elif [[ "$1" == mktemp ]]; then
      dir=$(mktemp -d "$REMOTE_TMP/step10f-frigate-mqtt.XXXXXX") || exit 1
      echo "$dir"
    elif [[ "$1" == bash && "$2" == -c && "$3" == 'umask 077; mkdir -p "$1"; cat > "$2"' ]]; then
      /bin/bash -c "$3" "$4" "$5" "$6"
    elif [[ "$1" == bash && "$2" == -c && "$3" == *mosquitto_sub* ]]; then
      [[ "$MQTT_SUB_FAIL" != 1 ]] || exit 1
      printf '%s\n' "$MQTT_MESSAGE"
    elif [[ "$1" == rm && "$2" == -rf && "$3" == -- ]]; then
      rm -rf -- "$4"
    else
      exit 0
    fi ;;
esac
'''
        pct = self.root / "bin/pct"
        pct.write_text(fake)
        pct.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / "bin") + ":" + os.environ["PATH"],
                        REMOTE_TMP=str(self.root / "remote-tmp"), MQTT_MESSAGE="online",
                        MQTT_SUB_FAIL="0", STATUS_FAIL="0", STATUS_STOPPED="0",
                        LOG_TEXT="", LOG_FILE=str(self.root / "operation.log"))

    def run_script(self, **extra):
        return subprocess.run(["bash", str(self.root / "scripts/step10f-frigate-mqtt-validation.sh")],
                              env=dict(self.env, **extra), text=True, capture_output=True)

    def temp_dirs(self):
        return list((self.root / "remote-tmp").iterdir())

    def test_success_cleans_unique_credentials_and_suppresses_secrets(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Frigate published MQTT availability: online", result.stdout)
        self.assertNotIn("test-password-not-secret", result.stdout + result.stderr)
        self.assertEqual(self.temp_dirs(), [])

    def test_missing_credentials_stop_before_temp_creation(self):
        (self.root / "config/local.conf").write_text('MQTT_USERNAME=""\nMQTT_PASSWORD=""\n')
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MQTT_USERNAME and MQTT_PASSWORD are required", result.stdout)
        self.assertEqual(self.temp_dirs(), [])

    def test_status_query_failure_is_not_reported_as_stopped(self):
        result = self.run_script(STATUS_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not query status for CT 200", result.stdout)
        self.assertNotIn("CT 200 is not running", result.stdout)
        self.assertEqual(self.temp_dirs(), [])

    def test_stopped_container_is_reported_as_stopped(self):
        result = self.run_script(STATUS_STOPPED="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CT 200 is not running", result.stdout)
        self.assertNotIn("Could not query status", result.stdout)
        self.assertEqual(self.temp_dirs(), [])

    def test_unsupported_credentials_are_rejected(self):
        (self.root / "config/local.conf").write_text(
            'MQTT_USERNAME="bad:user"\nMQTT_PASSWORD="test-password-not-secret"\n')
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported characters", result.stdout)
        self.assertEqual(self.temp_dirs(), [])

    def test_invalid_target_and_port_values_are_rejected(self):
        defaults_path = self.root / "config/defaults.conf"
        defaults_path.write_text(defaults_path.read_text().replace('DOCKER_CT_ID="200"',
                                                                   'DOCKER_CT_ID="200x"'))
        bad_target = self.run_script()
        self.assertNotEqual(bad_target.returncode, 0)
        self.assertIn("CT IDs must be numeric", bad_target.stdout)
        defaults_path.write_text(defaults_path.read_text().replace('DOCKER_CT_ID="200x"',
                                                                   'DOCKER_CT_ID="200"'))
        defaults_path.write_text(defaults_path.read_text().replace('MQTT_PORT="1883"',
                                                                   'MQTT_PORT="65536"'))
        bad_port = self.run_script()
        self.assertNotEqual(bad_port.returncode, 0)
        self.assertIn("MQTT_PORT must be an integer", bad_port.stdout)
        self.assertEqual(self.temp_dirs(), [])

    def test_missing_availability_message_fails_and_cleans(self):
        result = self.run_script(MQTT_MESSAGE="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No retained MQTT availability message", result.stdout)
        self.assertEqual(self.temp_dirs(), [])

    def test_historical_disconnect_is_warning_but_other_mqtt_error_fails(self):
        warning = self.run_script(LOG_TEXT="MQTT error: MQTT disconnected")
        self.assertEqual(warning.returncode, 0, warning.stdout + warning.stderr)
        self.assertIn("historical MQTT disconnects", warning.stdout)
        error = self.run_script(LOG_TEXT="MQTT connection refused")
        self.assertNotEqual(error.returncode, 0)
        self.assertIn("unexpected MQTT error-like", error.stdout)
        self.assertEqual(self.temp_dirs(), [])


if __name__ == "__main__":
    unittest.main()
