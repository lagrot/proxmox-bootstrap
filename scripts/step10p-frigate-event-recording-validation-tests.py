#!/usr/bin/env python3
"""Test Step 10P policy checks and operator paths without Proxmox or Frigate."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "frigate_event_recording_validation", REPO / "lib/frigate-event-recording-validation.py")
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


def record(**changes):
    result = {
        "enabled": True,
        "continuous": {"days": 0},
        "motion": {"days": 0},
        "alerts": {"pre_capture": 5, "post_capture": 5,
                    "retain": {"days": 10, "mode": "motion"}},
        "detections": {"pre_capture": 5, "post_capture": 5,
                       "retain": {"days": 10, "mode": "motion"}},
    }
    result.update(changes)
    return result


def api_config():
    return {"record": record(), "cameras": {
        "tplink_c200_1": {"record": record()},
        "tplink_c320ws_1": {"record": record()},
    }, "mqtt": {"password": "never-print-this-secret"}}


class PolicyTests(unittest.TestCase):
    def test_accepts_global_and_both_camera_policies(self):
        self.assertEqual(validator.validate(api_config(), 10, 5, 5,
                                           ["tplink_c200_1", "tplink_c320ws_1"]), [])

    def test_reports_mismatches_and_missing_camera(self):
        config = api_config()
        config["record"]["continuous"]["days"] = 1
        config["cameras"]["tplink_c200_1"]["record"]["alerts"]["retain"]["mode"] = "active_objects"
        del config["cameras"]["tplink_c320ws_1"]
        errors = validator.validate(config, 10, 5, 5,
                                    ["tplink_c200_1", "tplink_c320ws_1"])
        self.assertTrue(any("global config: continuous retention" in error for error in errors))
        self.assertTrue(any("alerts retention mode" in error for error in errors))
        self.assertTrue(any("camera missing" in error for error in errors))

    def test_rejects_invalid_json_shapes_nonfinite_and_bool_values(self):
        self.assertTrue(validator.validate([], 10, 5, 5, []))
        config = api_config()
        config["record"]["motion"]["days"] = True
        self.assertTrue(any("motion retention" in error for error in
                            validator.validate(config, 10, 5, 5, [])))
        config = api_config()
        config["record"]["alerts"]["pre_capture"] = True
        self.assertTrue(any("alerts pre_capture" in error for error in
                            validator.validate(config, 10, 5, 5, [])))
        config = api_config()
        config["record"]["alerts"]["retain"]["days"] = float("nan")
        self.assertTrue(any("alerts retention" in error for error in
                            validator.validate(config, 10, 5, 5, [])))


class OperatorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for folder in ("scripts", "lib", "config", "bin"):
            (self.root / folder).mkdir()
        shutil.copy(REPO / "scripts/step10p-frigate-event-recording-validation.sh", self.root / "scripts")
        shutil.copy(REPO / "lib/frigate-event-recording-validation.py", self.root / "lib")
        shutil.copy(REPO / "lib/common.sh", self.root / "lib")
        shutil.copy(REPO / "lib/logging.sh", self.root / "lib")
        shutil.copy(REPO / "config/defaults.conf", self.root / "config")
        pct = self.root / "bin/pct"
        pct.write_text(r'''#!/bin/bash
printf '%s\n' "$*" >> "$CALLS"
case "$1" in
  status)
    [[ "$STATUS_FAIL" != 1 ]] || { echo 'permission denied to Proxmox IPC' >&2; exit 1; }
    [[ "$STATUS_STOPPED" != 1 ]] && echo 'status: running' || echo 'status: stopped' ;;
  exec)
    shift 3
    case "$1" in
      ip) echo '2: eth0    inet 192.168.8.104/24 brd 192.168.8.255 scope global eth0' ;;
      docker)
        shift
        case "$1" in
          ps) [[ "$CONTAINER_STOPPED" == 1 ]] || echo frigate ;;
          inspect)
            if [[ "$*" == *'.State.Health'* ]]; then
              [[ "$UNHEALTHY" == 1 ]] && echo unhealthy || echo healthy
            else echo '2026-11-18T00:00:00Z'; fi ;;
          logs)
            [[ "$*" == *'--since 1h'* ]] || exit 3
            case "$LOG_ERROR" in
              1) echo '2026-11-18 13:00:00 [record] ERROR : Recording configuration failed' ;;
              2) echo '2026-11-18 13:00:00 [config] ERROR : Unable to parse YAML' ;;
              3) echo '2026-11-18 13:00:00 [record] ERROR : Error opening input file' ;;
            esac ;;
          *) exit 2 ;;
        esac ;;
      *) exit 2 ;;
    esac ;;
  *) exit 2 ;;
esac
''')
        pct.chmod(0o755)
        curl = self.root / "bin/curl"
        curl.write_text(r'''#!/bin/bash
[[ "$CURL_FAIL" != 1 ]] || exit 22
cat "$API_JSON"
''')
        curl.chmod(0o755)
        self.api_path = self.root / "api.json"
        self.api_path.write_text(json.dumps(api_config()))
        self.calls = self.root / "calls.log"
        self.env = dict(os.environ, PATH=f'{self.root / "bin"}:' + os.environ["PATH"],
                        API_JSON=str(self.api_path), CALLS=str(self.calls),
                        LOG_FILE=str(self.root / "operation.log"), STATUS_FAIL="0",
                        STATUS_STOPPED="0", CONTAINER_STOPPED="0", UNHEALTHY="0",
                        CURL_FAIL="0", LOG_ERROR="0")

    def run_script(self, *args, **changes):
        config_keys = {"FRIGATE_INTERNAL_PORT", "DOCKER_CT_ID", "TAPO_C200_NAME",
                       "FRIGATE_EVENT_RECORDING_DAYS"}
        config_changes = {key: changes.pop(key) for key in list(changes) if key in config_keys}
        local_conf = self.root / "config/local.conf"
        if config_changes:
            local_conf.write_text("".join(f'{key}="{value}"\n'
                                           for key, value in config_changes.items()))
        else:
            local_conf.unlink(missing_ok=True)
        return subprocess.run(["bash", str(self.root / "scripts/step10p-frigate-event-recording-validation.sh"),
                               *args], env=dict(self.env, **changes), text=True, capture_output=True)

    def test_help_and_invalid_arguments_make_no_guest_calls(self):
        help_result = self.run_script("--help")
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("read-only validation", help_result.stdout)
        bad = self.run_script("--unexpected")
        self.assertEqual(bad.returncode, 2)
        too_many = self.run_script("--help", "extra")
        self.assertEqual(too_many.returncode, 2)
        self.assertFalse(self.calls.exists())

    def test_healthy_route_passes_without_temp_file_or_secret_output(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Both cameras use event-only video retention", result.stdout)
        self.assertIn("No configuration or recording errors found in the last hour", result.stdout)
        self.assertNotIn("never-print-this-secret", result.stdout + result.stderr)
        self.assertNotIn("mktemp", self.calls.read_text() if self.calls.exists() else "")

    def test_proxmox_status_error_and_stopped_guest_are_distinguished(self):
        failed = self.run_script(STATUS_FAIL="1")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("permission denied to Proxmox IPC", failed.stdout)
        stopped = self.run_script(STATUS_STOPPED="1")
        self.assertNotEqual(stopped.returncode, 0)
        self.assertIn("is not running", stopped.stdout)

    def test_api_health_and_log_failures_fail_validation(self):
        api = self.run_script(CURL_FAIL="1")
        self.assertNotEqual(api.returncode, 0)
        self.assertIn("Could not read effective Frigate config", api.stdout)
        health = self.run_script(UNHEALTHY="1")
        self.assertNotEqual(health.returncode, 0)
        self.assertIn("Unexpected Frigate container health: unhealthy", health.stdout)
        logs = self.run_script(LOG_ERROR="1")
        self.assertNotEqual(logs.returncode, 0)
        self.assertIn("configuration or recording errors", logs.stdout)
        config_logger = self.run_script(LOG_ERROR="2")
        self.assertNotEqual(config_logger.returncode, 0)
        self.assertIn("configuration or recording errors", config_logger.stdout)
        record_logger_runtime = self.run_script(LOG_ERROR="3")
        self.assertEqual(record_logger_runtime.returncode, 0,
                         record_logger_runtime.stdout + record_logger_runtime.stderr)

    def test_invalid_runtime_inputs_stop_before_proxmox_access(self):
        for changes in ({"FRIGATE_INTERNAL_PORT": "0"},
                        {"FRIGATE_EVENT_RECORDING_DAYS": "0"},
                        {"TAPO_C200_NAME": "bad;name"},
                        {"TAPO_C200_NAME": "same", "TAPO_C320WS_NAME": "same"},
                        {"DOCKER_CT_ID": "200;bad"}):
            with self.subTest(changes=changes):
                self.calls.unlink(missing_ok=True)
                result = self.run_script(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
