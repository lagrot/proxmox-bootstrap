#!/usr/bin/env python3
"""Exercise Step 10N without contacting Proxmox or live services."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPT = "step10n-frigate-homeassistant-smoketest.sh"
TOKEN = "test.token_value-123"


class SmokeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("scripts", "config", "lib", "bin"):
            (self.root / name).mkdir()
        shutil.copy(REPO / "scripts" / SCRIPT, self.root / "scripts")
        shutil.copy(REPO / "config/defaults.conf", self.root / "config")
        for name in ("common.sh", "logging.sh"):
            shutil.copy(REPO / "lib" / name, self.root / "lib")
        (self.root / "config/local.conf").write_text(
            f'HA_TOKEN="{TOKEN}"\nMQTT_USERNAME="mqtt-user"\nMQTT_PASSWORD="mqtt-pass"\n'
        )

        self.qm_calls = self.root / "qm-calls"
        self.pct_calls = self.root / "pct-calls"
        self.curl_args = self.root / "curl-args"
        self.curl_config = self.root / "curl-config"
        self.curl_token_env = self.root / "curl-token-env"
        self.mqtt_config = self.root / "mqtt-config"
        qm = self.root / "bin/qm"
        qm.write_text(r'''#!/bin/bash
printf '%s\n' "$*" >> "$QM_CALLS"
[[ "${QM_FAIL:-0}" != 1 ]] || exit 1
cat <<'JSON'
[{"name" : "eth0","ip-addresses":[
 {
  "ip-address" : "127.0.0.1",
  "ip-address-type" : "ipv4"
 },
 {
  "ip-address" : "192.168.8.105",
  "ip-address-type" : "ipv4"
 }
]}]
JSON
''')
        qm.chmod(0o755)
        pct = self.root / "bin/pct"
        pct.write_text(r'''#!/bin/bash
joined="$*"
printf '%s\n' "$joined" >> "$PCT_CALLS"
case "$joined" in
  "status 200"|"status 210") printf 'status: running\n' ;;
  *"docker ps --format"*) printf 'frigate\n' ;;
  *"docker inspect --format"*) printf '%s\n' "${FRIGATE_HEALTH:-healthy}" ;;
  *"ip -4 -o addr show dev eth0"*) printf '2: eth0 inet 192.168.8.104/24 brd 192.168.8.255 scope global eth0\n' ;;
  *"grep -qxF"*) exit 0 ;;
  *"mktemp -d"*) printf '/tmp/frigate-ha-smoketest-mqtt.Abc123\n' ;;
  *"frigate/available"*) [[ "${MQTT_FAIL:-0}" != 1 ]] || exit 1; printf 'online\n' ;;
  *"frigate/events"*) [[ "${SMOKE_EVENT:-}" != 1 ]] || printf '{"type":"new"}\n' ;;
  *"find /mnt/frigate/recordings"*) ;;
  *"mkdir -p"*) cat > "$MQTT_CONFIG" ;;
  *"rm -rf"*) ;;
  *) printf 'Unexpected pct call: %s\n' "$joined" >&2; exit 91 ;;
esac
''')
        pct.chmod(0o755)
        curl = self.root / "bin/curl"
        curl.write_text(r'''#!/bin/bash
printf '%s\n' "$*" >> "$CURL_ARGS"
printf '%s' "${HA_TOKEN-}" > "$CURL_TOKEN_ENV"
if [[ " $* " == *" --config - "* ]]; then cat > "$CURL_CONFIG"; else cat >/dev/null; fi
output=""
while (($#)); do
  if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi
done
[[ -z "$output" ]] || printf '%s\n' "${HA_STATES_JSON}" > "$output"
printf '%s' "${HA_HTTP_CODE:-200}"
''')
        curl.chmod(0o755)

        entity_ids = []
        for camera in ("tplink_c200_1", "tplink_c320ws_1"):
            entity_ids.extend((f"camera.{camera}", f"switch.{camera}_detect",
                               f"switch.{camera}_recordings", f"switch.{camera}_snapshots",
                               f"binary_sensor.{camera}_motion", f"sensor.{camera}_review_status"))
        self.states_json = json.dumps([
            {"entity_id": entity, "state": "recording" if entity.startswith("camera.") else "on"}
            for entity in entity_ids
        ])
        self.env = dict(
            os.environ, PATH=f"{self.root / 'bin'}:{os.environ['PATH']}",
            LOG_FILE=str(self.root / "logs/test.log"), QM_CALLS=str(self.qm_calls),
            PCT_CALLS=str(self.pct_calls), CURL_ARGS=str(self.curl_args),
            CURL_CONFIG=str(self.curl_config), CURL_TOKEN_ENV=str(self.curl_token_env),
            MQTT_CONFIG=str(self.mqtt_config), HA_STATES_JSON=self.states_json, HA_TOKEN=TOKEN,
        )

    def run_script(self, *args, **overrides):
        return subprocess.run(
            ["bash", str(self.root / "scripts" / SCRIPT), *args],
            env=dict(self.env, **overrides), text=True, capture_output=True,
        )

    @staticmethod
    def read(path):
        return path.read_text() if path.exists() else ""

    def test_documented_command_passes_when_no_camera_activity_occurs(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Smoke test completed successfully", result.stdout)
        self.assertIn("live event check skipped; use --check-activity", result.stdout)
        self.assertIn("recent event recording check skipped; use --check-activity", result.stdout)

    def test_bearer_token_is_sent_on_stdin_not_in_args_or_environment(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(TOKEN, self.read(self.curl_config))
        self.assertNotIn(TOKEN, self.read(self.curl_args))
        self.assertEqual(self.read(self.curl_token_env), "")
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        pct_calls = self.read(self.pct_calls)
        self.assertNotIn("mqtt-user", pct_calls)
        self.assertNotIn("mqtt-pass", pct_calls)
        self.assertIn("mktemp -d /tmp/frigate-ha-smoketest-mqtt.XXXXXX", pct_calls)
        self.assertIn("rm -rf /tmp/frigate-ha-smoketest-mqtt.Abc123", pct_calls)

    def test_activity_check_is_opt_in_and_missing_activity_is_only_a_warning(self):
        result = self.run_script("--check-activity")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no recent event recording found", result.stdout)
        self.assertIn("no live Frigate MQTT event received", result.stdout)
        self.assertIn("Smoke test passed with activity-dependent warnings", result.stdout)

        self.pct_calls.unlink(missing_ok=True)
        result = self.run_script("--check-activity", SMOKE_EVENT="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("live Frigate MQTT event received", result.stdout)

    def test_missing_entities_unhealthy_service_and_http_errors_fail(self):
        result = self.run_script(HA_STATES_JSON=json.dumps([
            {"entity_id": "camera.tplink_c200_1", "state": "recording"}
        ]))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required Home Assistant entities are missing or unavailable", result.stdout)

        self.pct_calls.unlink(missing_ok=True)
        result = self.run_script(FRIGATE_HEALTH="unhealthy")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Frigate health is unhealthy", result.stdout)

        self.pct_calls.unlink(missing_ok=True)
        result = self.run_script(HA_HTTP_CODE="503")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Home Assistant API returned HTTP 503", result.stdout)

        self.pct_calls.unlink(missing_ok=True)
        result = self.run_script(QM_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Home Assistant IP not detected", result.stdout)

    def test_bad_arguments_and_token_fail_before_service_calls(self):
        for args in (("--unknown",), ("--help", "extra"), ("--check-activity", "extra")):
            result = self.run_script(*args)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        (self.root / "config/local.conf").write_text('HA_TOKEN="bad\ntoken"\n')
        result = self.run_script()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.read(self.qm_calls), "")
        self.assertEqual(self.read(self.pct_calls), "")
        self.assertEqual(self.read(self.curl_args), "")

        (self.root / "config/local.conf").write_text(
            f'HA_TOKEN="{TOKEN}"\nMQTT_USERNAME="mqtt-user"\nMQTT_PASSWORD="mqtt-pass"\nMQTT_PORT="1883;bad"\n'
        )
        result = self.run_script()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("MQTT_PORT must be an integer", result.stdout)
        self.assertEqual(self.read(self.pct_calls), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
