#!/usr/bin/env python3
"""Exercise Step 10L reload control flow without contacting Home Assistant."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class FrigateReloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("scripts", "config", "lib", "bin"):
            (self.root / name).mkdir()
        shutil.copy(REPO / "scripts/step10l-homeassistant-frigate-reload.sh", self.root / "scripts")
        shutil.copy(REPO / "config/defaults.conf", self.root / "config")
        for name in ("common.sh", "logging.sh"):
            shutil.copy(REPO / "lib" / name, self.root / "lib")

        qm = self.root / "bin/qm"
        qm.write_text(r'''#!/bin/bash
printf '%s\n' "$*" >> "$QM_CALLS"
[[ "$QM_FAIL" != 1 ]] || exit 1
cat <<'JSON'
[{"name":"eth0","ip-addresses":[
 {"ip-address":"127.0.0.1","ip-address-type":"ipv4"},
 {"ip-address":"172.30.0.1","ip-address-type":"ipv4"},
 {"ip-address":"192.168.8.105","ip-address-type":"ipv4"},
 {"ip-address":"2001:db8::1","ip-address-type":"ipv6"}
]}]
JSON
''')
        qm.chmod(0o755)
        curl = self.root / "bin/curl"
        curl.write_text(r'''#!/bin/bash
printf '%s\n' "$*" >> "$CURL_CALLS"
printf '%s' "${HA_TOKEN-}" > "$CURL_TOKEN_ENV"
cat >> "$CURL_STDIN"
last=""; method="GET"
while (($#)); do
  [[ "$1" != -X ]] || { method="$2"; shift; }
  last="$1"; shift
done
case "$CURL_MODE:$method:$last" in
  template-fail:POST:*/api/template) printf '\n500' ;;
  template-invalid:POST:*/api/template) printf 'None\n200' ;;
  reload-fail:POST:*/reload_config_entry) printf '\n500' ;;
  *:POST:*/api/template) printf '0123456789abcdef0123456789abcdef\n200' ;;
  state-unavailable:GET:*/api/states/*) printf '{"state":"unavailable"}\n200' ;;
  *)
    if [[ "$method" == POST ]]; then printf '\n200'
    else printf '{"state":"recording"}\n200'; fi ;;
esac
''')
        curl.chmod(0o755)
        sleep = self.root / "bin/sleep"
        sleep.write_text("#!/bin/sh\nexit 0\n")
        sleep.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.root / 'bin'}:{os.environ['PATH']}",
                        HA_TOKEN="test.token_value-123", QM_CALLS=str(self.root / "qm-calls"),
                        CURL_CALLS=str(self.root / "curl-calls"), CURL_STDIN=str(self.root / "curl-stdin"),
                        CURL_TOKEN_ENV=str(self.root / "curl-token-env"),
                        QM_FAIL="0", CURL_MODE="success")

    def run_script(self, *args, **overrides):
        return subprocess.run(["bash", str(self.root / "scripts/step10l-homeassistant-frigate-reload.sh"), *args],
                              env=dict(self.env, **overrides), text=True, capture_output=True)

    def read_calls(self, name):
        path = self.root / name
        return path.read_text() if path.exists() else ""

    def test_documented_dry_run_does_not_contact_vm_or_api(self):
        result = self.run_script("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Would detect Home Assistant VM 100 IP", result.stdout)
        self.assertIn("No changes were made", result.stdout)
        self.assertEqual(self.read_calls("qm-calls"), "")
        self.assertEqual(self.read_calls("curl-calls"), "")

    def test_invalid_inputs_stop_before_vm_or_api_calls(self):
        invalid_profile = self.run_script(TAPO_CAMERA_PROFILE="other")
        self.assertNotEqual(invalid_profile.returncode, 0)
        invalid_entity = self.run_script(HA_FRIGATE_RELOAD_ENTITY='camera.x"; curl evil')
        self.assertEqual(invalid_entity.returncode, 2)
        invalid_token = self.run_script(HA_TOKEN="bad\ntoken")
        self.assertEqual(invalid_token.returncode, 2)
        local_conf = self.root / "config/local.conf"
        local_conf.write_text('HA_VM_ID="100x"\n')
        invalid_vm = self.run_script()
        self.assertEqual(invalid_vm.returncode, 2)
        local_conf.write_text('HA_HTTP_PORT="70000"\n')
        invalid_port = self.run_script()
        self.assertEqual(invalid_port.returncode, 2)
        local_conf.unlink()
        bad_argument = self.run_script("--apply")
        self.assertEqual(bad_argument.returncode, 2)
        self.assertEqual(self.read_calls("qm-calls"), "")
        self.assertEqual(self.read_calls("curl-calls"), "")

    def test_reload_succeeds_and_bearer_token_is_not_in_process_arguments(self):
        result = self.run_script(TAPO_CAMERA_PROFILE="c320ws")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Home Assistant reports camera.tplink_c320ws_1 state: recording", result.stdout)
        self.assertNotIn("test.token_value-123", result.stdout + result.stderr)
        self.assertNotIn("test.token_value-123", self.read_calls("curl-calls"))
        self.assertEqual(self.read_calls("curl-token-env"), "")
        self.assertIn("test.token_value-123", self.read_calls("curl-stdin"))
        self.assertIn("192.168.8.105", self.read_calls("curl-calls"))
        self.assertIn('config_entry_id(\'camera.tplink_c200_1\')', self.read_calls("curl-calls"))
        self.assertIn('"entry_id":"0123456789abcdef0123456789abcdef"', self.read_calls("curl-calls"))

    def test_http_reload_failure_and_missing_camera_state_fail(self):
        reload_failure = self.run_script(CURL_MODE="reload-fail")
        self.assertNotEqual(reload_failure.returncode, 0)
        self.assertIn("returned HTTP 500", reload_failure.stdout)
        self.assertEqual(self.read_calls("curl-calls").count("/api/states/"), 0)

        self.root.joinpath("qm-calls").unlink(missing_ok=True)
        self.root.joinpath("curl-calls").unlink(missing_ok=True)
        unavailable = self.run_script(CURL_MODE="state-unavailable")
        self.assertNotEqual(unavailable.returncode, 0)
        self.assertIn("did not expose an available", unavailable.stdout)
        self.assertEqual(self.read_calls("curl-calls").count("/api/states/"), 10)

    def test_config_entry_lookup_failure_stops_before_reload(self):
        http_error = self.run_script(CURL_MODE="template-fail")
        self.assertNotEqual(http_error.returncode, 0)
        self.assertIn("config-entry lookup returned HTTP 500", http_error.stdout)
        self.assertEqual(self.read_calls("curl-calls").count("reload_config_entry"), 0)

        self.root.joinpath("curl-calls").unlink(missing_ok=True)
        invalid_id = self.run_script(CURL_MODE="template-invalid")
        self.assertNotEqual(invalid_id.returncode, 0)
        self.assertIn("invalid config-entry ID", invalid_id.stdout)
        self.assertEqual(self.read_calls("curl-calls").count("reload_config_entry"), 0)

    def test_guest_agent_failure_stops_before_api_call(self):
        result = self.run_script(QM_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not detect the Home Assistant IPv4 address", result.stdout)
        self.assertEqual(self.read_calls("curl-calls"), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
