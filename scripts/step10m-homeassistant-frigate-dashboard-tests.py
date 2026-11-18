#!/usr/bin/env python3
"""Mocked Step 10M CLI and Home Assistant WebSocket safety tests."""

import base64
import importlib.util
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]
CLIENT_PATH = REPO / "scripts/step10m-homeassistant-frigate-dashboard-client.py"


class FakeWebSocket:
    def __init__(self, *, dashboards=None, states=None, fail_type=None, auth_ok=True):
        self.messages = [{"type": "auth_required"}]
        self.sent = []
        self.dashboards = dashboards or []
        self.states = states or []
        self.fail_type = fail_type
        self.failed = False
        self.auth_ok = auth_ok
        self.closed = False

    def recv(self):
        return json.dumps(self.messages.pop(0))

    def send(self, raw):
        message = json.loads(raw)
        self.sent.append(message)
        if message.get("type") == "auth":
            self.messages.append({"type": "auth_ok" if self.auth_ok else "auth_invalid"})
            return
        result_by_type = {
            "lovelace/dashboards/list": self.dashboards,
            "lovelace/config": {"views": [{"title": "Previous dashboard"}]},
            "get_states": self.states,
            "lovelace/dashboards/create": {"id": "created-dashboard-id", "url_path": message.get("url_path")},
            "lovelace/config/save": None,
            "lovelace/dashboards/delete": None,
        }
        if message["type"] == self.fail_type and not self.failed:
            self.failed = True
            self.messages.append({"id": message["id"], "success": False,
                                  "error": {"message": "mock failure"}})
        else:
            self.messages.append({"id": message["id"], "success": True,
                                  "result": result_by_type[message["type"]]})

    def close(self):
        self.closed = True


def load_client():
    module_name = "step10m_dashboard_client_test"
    websocket_module = types.SimpleNamespace(create_connection=None)
    with patch.dict(sys.modules, {"websocket": websocket_module}):
        spec = importlib.util.spec_from_file_location(module_name, CLIENT_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module, websocket_module


class DashboardClientTests(unittest.TestCase):
    def setUp(self):
        self.client, self.websocket = load_client()
        self.config = {
            "views": [{"cards": [{"entity": "camera.tplink_c200_1"},
                                  {"entities": ["sensor.tplink_c200_1_person_count"]}]}]
        }
        self.states = [{"entity_id": "camera.tplink_c200_1"},
                       {"entity_id": "sensor.tplink_c200_1_person_count"}]
        self.env = {
            "HA_DASHBOARD_URL_PATH": "frigate-dashboard",
            "HA_DASHBOARD_TITLE": "Frigate",
            "HA_DASHBOARD_ICON": "mdi:cctv",
            "FORCE_UPDATE": "0",
            "DASHBOARD_CONFIG_B64": base64.b64encode(json.dumps(self.config).encode()).decode(),
        }

    def run_client(self, ws, *, force="0"):
        self.websocket.create_connection = lambda *_args, **_kwargs: ws
        env = dict(self.env, FORCE_UPDATE=force)
        with patch.dict(os.environ, env, clear=False), \
                patch("sys.stdin", io_string(json.dumps({"token": "token-from-stdin"}))), \
                patch("sys.stdout", io_string()), patch("sys.stderr", io_string()):
            self.client.main()
            return sys.stdout.getvalue(), list(ws.sent)

    def test_new_dashboard_validates_entities_before_create_then_saves(self):
        ws = FakeWebSocket(states=self.states)
        output, sent = self.run_client(ws)
        types_sent = [item["type"] for item in sent]
        self.assertLess(types_sent.index("get_states"), types_sent.index("lovelace/dashboards/create"))
        self.assertLess(types_sent.index("lovelace/dashboards/create"), types_sent.index("lovelace/config/save"))
        self.assertIn("dashboard_entities_validated=2", output)
        self.assertTrue(ws.closed)

    def test_missing_entity_stops_before_dashboard_creation(self):
        ws = FakeWebSocket(states=[{"entity_id": "camera.tplink_c200_1"}])
        with self.assertRaisesRegex(RuntimeError, "sensor.tplink_c200_1_person_count"):
            self.run_client(ws)
        self.assertNotIn("lovelace/dashboards/create", [item["type"] for item in ws.sent])
        self.assertNotIn("lovelace/config/save", [item["type"] for item in ws.sent])

    def test_existing_dashboard_is_preserved_without_force(self):
        ws = FakeWebSocket(dashboards=[{"url_path": "frigate-dashboard"}])
        output, sent = self.run_client(ws)
        self.assertIn("dashboard_exists=frigate-dashboard", output)
        self.assertEqual([item["type"] for item in sent], ["auth", "lovelace/dashboards/list"])

    def test_force_update_validates_then_saves_existing_dashboard(self):
        ws = FakeWebSocket(dashboards=[{"url_path": "frigate-dashboard"}], states=self.states)
        output, sent = self.run_client(ws, force="1")
        self.assertIn("dashboard_update=enabled", output)
        self.assertNotIn("lovelace/dashboards/create", [item["type"] for item in sent])
        self.assertEqual(sent[-1]["type"], "lovelace/config/save")

    def test_forced_update_restores_previous_config_if_save_fails(self):
        ws = FakeWebSocket(dashboards=[{"url_path": "frigate-dashboard"}],
                           states=self.states, fail_type="lovelace/config/save")
        with self.assertRaisesRegex(RuntimeError, "previous configuration was restored"):
            self.run_client(ws, force="1")
        saves = [item for item in ws.sent if item["type"] == "lovelace/config/save"]
        self.assertEqual(len(saves), 2)
        self.assertEqual(saves[1]["config"], {"views": [{"title": "Previous dashboard"}]})

    def test_auth_and_lookup_failures_do_not_write_dashboard(self):
        auth_failure = FakeWebSocket(auth_ok=False)
        with self.assertRaisesRegex(RuntimeError, "authentication failed"):
            self.run_client(auth_failure)
        self.assertEqual(len(auth_failure.sent), 1)

        lookup_failure = FakeWebSocket(fail_type="get_states")
        with self.assertRaisesRegex(RuntimeError, "mock failure"):
            self.run_client(lookup_failure)
        self.assertNotIn("lovelace/dashboards/create", [item["type"] for item in lookup_failure.sent])

    def test_save_failure_removes_new_empty_dashboard(self):
        ws = FakeWebSocket(states=self.states, fail_type="lovelace/config/save")
        with self.assertRaisesRegex(RuntimeError, "mock failure"):
            self.run_client(ws)
        types_sent = [item["type"] for item in ws.sent]
        self.assertIn("lovelace/dashboards/delete", types_sent)
        delete = next(item for item in ws.sent if item["type"] == "lovelace/dashboards/delete")
        self.assertEqual(delete["dashboard_id"], "created-dashboard-id")


def io_string(initial=""):
    from io import StringIO
    return StringIO(initial)


class DashboardShellTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("scripts", "config", "lib", "bin"):
            (self.root / name).mkdir()
        for name in ("step10m-homeassistant-frigate-dashboard.sh",
                     "step10m-homeassistant-frigate-dashboard-client.py"):
            shutil.copy(REPO / "scripts" / name, self.root / "scripts")
        shutil.copy(REPO / "config/defaults.conf", self.root / "config")
        for name in ("common.sh", "logging.sh"):
            shutil.copy(REPO / "lib" / name, self.root / "lib")

        self.qm_calls = self.root / "qm-calls"
        self.qm_input = self.root / "qm-input"
        self.pct_calls = self.root / "pct-calls"
        qm = self.root / "bin/qm"
        qm.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$QM_CALLS"
cat > "$QM_INPUT"
[[ "${QM_FAIL-0}" != 1 ]] || exit 1
printf 'dashboard_created=frigate-dashboard\\n'
''')
        qm.chmod(0o755)
        pct = self.root / "bin/pct"
        pct.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$PCT_CALLS"
printf '[{"ifname":"eth0","addr_info":[{"family":"inet","local":"192.168.8.104"}]}]\\n'
''')
        pct.chmod(0o755)
        self.env = dict(os.environ,
                        PATH=f"{self.root / 'bin'}:{os.environ['PATH']}",
                        LOG_FILE=str(self.root / "logs/test.log"),
                        QM_CALLS=str(self.qm_calls), QM_INPUT=str(self.qm_input),
                        PCT_CALLS=str(self.pct_calls), HA_TOKEN="secret.token_value_123")
        (self.root / "config/local.conf").write_text('HA_TOKEN="secret.token_value_123"\n')

    def run_script(self, *args, **overrides):
        return subprocess.run(["bash", str(self.root / "scripts/step10m-homeassistant-frigate-dashboard.sh"), *args],
                              env=dict(self.env, **overrides), text=True, capture_output=True)

    def test_documented_dry_run_makes_no_guest_or_api_calls_and_needs_no_token(self):
        result = self.run_script("--dry-run", HA_TOKEN="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no Proxmox guest or Home Assistant API calls", result.stdout)
        self.assertIn("No changes were made", result.stdout)
        self.assertFalse(self.qm_calls.exists())
        self.assertFalse(self.pct_calls.exists())

    def test_apply_passes_token_only_via_stdin_and_never_in_args_or_output(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = self.qm_calls.read_text()
        stdin = self.qm_input.read_text()
        self.assertIn("--pass-stdin", args)
        self.assertIn("secret.token_value_123", stdin)
        self.assertNotIn("secret.token_value_123", args)
        self.assertNotIn("secret.token_value_123", result.stdout + result.stderr)
        self.assertNotIn("HASS_TOKEN", args)
        self.assertTrue(self.pct_calls.exists())
        config_b64 = next(part.split("=", 1)[1] for part in shlex.split(args)
                          if part.startswith("DASHBOARD_CONFIG_B64="))
        dashboard = json.loads(base64.b64decode(config_b64))
        self.assertIn("https://192.168.8.104:8971", json.dumps(dashboard))

    def test_invalid_configuration_stops_before_guest_queries(self):
        (self.root / "config/local.conf").write_text(
            'HA_TOKEN="secret.token_value_123"\nHA_DASHBOARD_URL_PATH="bad/path"\n')
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lowercase URL slug", result.stdout)
        self.assertFalse(self.qm_calls.exists())
        self.assertFalse(self.pct_calls.exists())

    def test_guest_agent_failure_is_reported(self):
        result = self.run_script(QM_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("guest-agent dashboard command failed", result.stdout)
        self.assertNotIn("secret.token_value_123", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
