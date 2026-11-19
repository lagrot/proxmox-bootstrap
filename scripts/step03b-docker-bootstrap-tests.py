#!/usr/bin/env python3
"""Test Step 03B dry-run and Proxmox status handling without a guest."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class DockerBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for folder in ("scripts", "lib", "config", "bin"):
            (self.root / folder).mkdir()
        shutil.copy(REPO / "scripts/step03b-docker-bootstrap.sh", self.root / "scripts")
        for name in ("cli.sh", "common.sh", "validation.sh", "runtime.sh", "logging.sh"):
            shutil.copy(REPO / "lib" / name, self.root / "lib")
        shutil.copy(REPO / "config/defaults.conf", self.root / "config")
        pct = self.root / "bin/pct"
        pct.write_text(r'''#!/bin/bash
printf '%s\n' "$*" >> "$PCT_LOG"
case "$1" in
 status)
   case "$STATUS_MODE" in
     running) echo 'status: running' ;;
     stopped) echo 'status: stopped' ;;
     missing) echo "Configuration file 'nodes/test/lxc/$2.conf' does not exist" >&2; exit 1 ;;
     error) echo 'permission denied to Proxmox IPC' >&2; exit 1 ;;
     *) exit 2 ;;
   esac ;;
 start|stop|exec) echo "unexpected mutation or guest call: $*" >&2; exit 9 ;;
 *) exit 2 ;;
esac
''')
        pct.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.root / "bin"}:' + os.environ["PATH"],
                        PCT_LOG=str(self.root / "pct.log"),
                        LOG_FILE=str(self.root / "operations.log"),
                        STATUS_MODE="running")

    def run_script(self, *args, **changes):
        return subprocess.run(["bash", str(self.root / "scripts/step03b-docker-bootstrap.sh"), *args],
                              env=dict(self.env, **changes), text=True, capture_output=True)

    def test_stopped_container_dry_run_prints_start_without_mutating_or_logging(self):
        result = self.run_script("--dry-run", STATUS_MODE="stopped")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[DRY-RUN] pct start 200", result.stdout)
        self.assertIn("[DRY-RUN] Skipping wait for container readiness", result.stdout)
        calls = (self.root / "pct.log").read_text().splitlines()
        self.assertEqual(calls, ["status 200", "status 200"])
        self.assertFalse((self.root / "operations.log").exists())

    def test_running_container_dry_run_only_queries_status(self):
        result = self.run_script("--dry-run", STATUS_MODE="running")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.root / "pct.log").read_text().splitlines()
        self.assertEqual(calls, ["status 200", "status 200"])
        self.assertIn("[DRY-RUN] pct exec 200 -- bash -c apt-get update", result.stdout)
        self.assertFalse((self.root / "operations.log").exists())

    def test_status_query_error_aborts_instead_of_starting_container(self):
        result = self.run_script(STATUS_MODE="error")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not query status for CT 200", result.stdout)
        calls = (self.root / "pct.log").read_text().splitlines()
        self.assertEqual(calls, ["status 200"])
        self.assertNotIn("start 200", calls)

    def test_missing_container_fails_with_step03_guidance(self):
        result = self.run_script(STATUS_MODE="missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Run step03-docker-lxc.sh first", result.stdout)
        self.assertEqual((self.root / "pct.log").read_text().splitlines(), ["status 200"])


if __name__ == "__main__":
    unittest.main()
