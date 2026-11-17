#!/usr/bin/env python3
"""Exercise Step 10E restart preflight, dry-run, and failure handling."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class FrigateRestartTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("scripts", "config", "lib", "bin"):
            (self.root / name).mkdir()
        for name in ("common.sh", "logging.sh"):
            shutil.copy(REPO / "lib" / name, self.root / "lib" / name)
        defaults = (REPO / "config/defaults.conf").read_text()
        (self.root / "config/defaults.conf").write_text(defaults)
        shutil.copy(REPO / "scripts/step10e-frigate-restart.sh",
                    self.root / "scripts/step10e-frigate-restart.sh")
        fake = r'''#!/bin/bash
case "$1" in
  status) echo 'status: running' ;;
  exec)
    shift 3
    command="$*"
    if [[ "$command" == systemctl\ is-active* ]]; then
      [[ "$DOCKER_DOWN" != 1 ]] ; exit $?
    elif [[ "$command" == docker\ compose\ version ]]; then
      exit 0
    elif [[ "$command" == *'docker compose config'* ]]; then
      [[ "$COMPOSE_INVALID" != 1 ]] ; exit $?
    elif [[ "$command" == docker\ inspect\ frigate ]]; then
      [[ "$NO_CONTAINER" != 1 ]] ; exit $?
    elif [[ "$command" == *'docker compose restart frigate'* ]]; then
      echo restart >> "$EVENTS"
      [[ "$RESTART_FAIL" != 1 ]] ; exit $?
    elif [[ "$command" == docker\ ps* ]]; then
      [[ "$NO_RUNNING" != 1 ]] && echo frigate
    elif [[ "$command" == docker\ inspect\ --format* ]]; then
      echo "$HEALTH"
    elif [[ "$command" == curl\ * ]]; then
      echo "$HTTP_CODE"
    elif [[ "$command" == docker\ logs* ]]; then
      echo 'simulated log output'
    else
      exit 0
    fi ;;
esac
'''
        for name, content in (("pct", fake), ("sleep", "#!/bin/sh\nexit 0\n")):
            path = self.root / "bin" / name
            path.write_text(content)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / "bin") + ":" + os.environ["PATH"],
                        EVENTS=str(self.root / "events"), DOCKER_DOWN="0", COMPOSE_INVALID="0",
                        NO_CONTAINER="0", RESTART_FAIL="0", NO_RUNNING="0", HEALTH="healthy",
                        HTTP_CODE="200", LOG_FILE=str(self.root / "operation.log"))

    def run_script(self, *args, **extra):
        return subprocess.run(["bash", str(self.root / "scripts/step10e-frigate-restart.sh"), *args],
                              env=dict(self.env, **extra), text=True, capture_output=True)

    def restarts(self):
        return (self.root / "events").read_text().count("restart") if (self.root / "events").exists() else 0

    def test_help_and_invalid_option(self):
        help_result = self.run_script("--help")
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("Usage:", help_result.stdout)
        invalid = self.run_script("--bad")
        self.assertNotEqual(invalid.returncode, 0)
        self.assertEqual(self.restarts(), 0)

    def test_dry_run_checks_preflight_without_restart_or_log_write(self):
        result = self.run_script("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("No restart was performed", result.stdout)
        self.assertEqual(self.restarts(), 0)
        self.assertFalse((self.root / "operation.log").exists())

    def test_successful_restart_passes_health_and_https_checks(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Frigate restart completed successfully", result.stdout)
        self.assertEqual(self.restarts(), 1)

    def test_compose_or_missing_container_preflight_prevents_restart(self):
        invalid_compose = self.run_script(COMPOSE_INVALID="1")
        self.assertNotEqual(invalid_compose.returncode, 0)
        self.assertIn("configuration is invalid", invalid_compose.stdout)
        missing_container = self.run_script(NO_CONTAINER="1")
        self.assertNotEqual(missing_container.returncode, 0)
        self.assertIn("container does not exist", missing_container.stdout)
        self.assertEqual(self.restarts(), 0)

    def test_unhealthy_container_and_http_error_fail(self):
        unhealthy = self.run_script(HEALTH="unhealthy")
        self.assertNotEqual(unhealthy.returncode, 0)
        self.assertIn("container is unhealthy", unhealthy.stdout)
        bad_http = self.run_script(HTTP_CODE="500")
        self.assertNotEqual(bad_http.returncode, 0)
        self.assertIn("HTTP 500", bad_http.stdout)

    def test_invalid_port_is_rejected_before_restart(self):
        defaults = self.root / "config/defaults.conf"
        defaults.write_text(defaults.read_text().replace('FRIGATE_WEB_PORT="8971"',
                                                          'FRIGATE_WEB_PORT="70000"'))
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("port must be an integer", result.stdout)
        self.assertEqual(self.restarts(), 0)


if __name__ == "__main__":
    unittest.main()
