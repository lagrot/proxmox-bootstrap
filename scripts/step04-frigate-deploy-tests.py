#!/usr/bin/env python3
"""Exercise Step 04 deployment safety with isolated paths and fake Proxmox tools."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class FrigateDeployTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("scripts", "config", "lib", "bin", "media", "app"):
            (self.root / name).mkdir()
        for name in ("common.sh", "logging.sh"):
            shutil.copy(REPO / "lib" / name, self.root / "lib" / name)
        defaults = (REPO / "config/defaults.conf").read_text()
        defaults = defaults.replace('FRIGATE_MOUNTPOINT="/mnt/frigate"',
                                    f'FRIGATE_MOUNTPOINT="{self.root / "media"}"')
        defaults = defaults.replace('FRIGATE_APP_DIR="/opt/frigate"',
                                    f'FRIGATE_APP_DIR="{self.root / "app"}"')
        device = self.root / "device"
        device.touch()
        stable_device = self.root / "by-id-device"
        stable_device.symlink_to(device)
        defaults = defaults.replace(
            'FRIGATE_DEVICE_BY_ID="/dev/disk/by-id/ata-PNY_500GB_SATA_SSD_PNH05266000310302979-part1"',
            f'FRIGATE_DEVICE_BY_ID="{stable_device}"')
        (self.root / "config/defaults.conf").write_text(defaults)
        script = (REPO / "scripts/step04-frigate-deploy.sh").read_text()
        script = script.replace('/opt/frigate', str(self.root / "app"))
        script = script.replace('FRIGATE_MEDIA_DIR="${FRIGATE_MEDIA_DIR:-/mnt/frigate}"',
                                f'FRIGATE_MEDIA_DIR="${{FRIGATE_MEDIA_DIR:-{self.root / "media"}}}"')
        (self.root / "scripts/step04-frigate-deploy.sh").write_text(script)
        fake = r'''#!/bin/bash
name=$(basename "$0")
printf '%s %s\n' "$name" "$*" >> "$EVENTS"
case "$name" in
  findmnt)
    [[ -f "$MOUNTED" ]] || exit 1
    if [[ "$1" == -n ]]; then printf '%s %s\n' "$TEST_MOUNT_SOURCE" "$TEST_MOUNT_FSTYPE"; fi ;;
  sleep) exit 0 ;;
  curl) echo 200 ;;
  pct)
    case "$1" in
      config) [[ ! -f "$NO_CT" ]] ;;
      status)
        [[ "${STATUS_FAIL:-0}" != 1 ]] || exit 1
        printf 'status: %s\n' "${CT_STATUS:-running}" ;;
      push) exit 0 ;;
      exec)
        shift 3
        case "$*" in
          *'test ! -e'* ) [[ ! -f "$EXISTING" ]] ;;
          'docker version'|'docker compose version'|'systemctl is-active --quiet docker') exit 0 ;;
          *'command -v ffmpeg'* ) exit 0 ;;
          'test -e /dev/dri/renderD128'|'test -d /dev/bus/usb') exit 0 ;;
          'test -d '*) [[ -d "${*: -1}" ]] ;;
          'touch '*) touch "${*: -1}" ;;
          'rm -f '*) rm -f "${*: -1}" ;;
          mkdir\ -p\ *) exit 0 ;;
          *'docker compose config'*|*'docker compose pull'*|*'docker compose up -d'*) exit 0 ;;
          'docker ps '*) echo frigate ;;
          'bash -c command -v curl'* ) exit 0 ;;
          'curl '*) echo 200 ;;
          *) exit 0 ;;
        esac ;;
    esac ;;
esac
'''
        chown = '''#!/bin/bash
printf 'chown %s\\n' "$*" >> "$EVENTS"
'''
        for name in ("pct", "findmnt", "sleep", "curl"):
            path = self.root / "bin" / name
            path.write_text(fake)
            path.chmod(0o755)
        (self.root / "bin/chown").write_text(chown)
        (self.root / "bin/chown").chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / "bin") + ":" + os.environ["PATH"],
                        EVENTS=str(self.root / "events"), MOUNTED=str(self.root / "mounted"),
                        NO_CT=str(self.root / "no-ct"), EXISTING=str(self.root / "existing"),
                        TEST_MOUNT_SOURCE=str(device), TEST_MOUNT_FSTYPE="xfs",
                        STATUS_FAIL="0", CT_STATUS="running",
                        FRIGATE_APP_DIR=str(self.root / "app"),
                        FRIGATE_MEDIA_DIR=str(self.root / "media"),
                        LOG_FILE=str(self.root / "operation.log"))
        (self.root / "media/clips").mkdir()
        (self.root / "mounted").touch()

    def run_script(self, *args, **extra):
        env = dict(self.env, **extra)
        return subprocess.run(["bash", str(self.root / "scripts/step04-frigate-deploy.sh"), *args],
                              env=env, text=True, capture_output=True)

    def events(self):
        return (self.root / "events").read_text() if (self.root / "events").exists() else ""

    def test_dry_run_is_non_mutating_and_does_not_require_new_media_dirs(self):
        result = self.run_script("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("DRY-RUN", result.stdout)
        self.assertNotIn("apt-get", self.events())
        self.assertNotIn("pct push", self.events())
        self.assertFalse((self.root / "operation.log").exists())
        self.assertEqual(list((self.root / "media").iterdir()), [self.root / "media/clips"])

    def test_missing_mount_and_unexpected_path_stop_before_changes(self):
        (self.root / "mounted").unlink()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a mounted filesystem", result.stdout)
        self.assertNotIn("chown", self.events())
        self.assertNotIn("apt-get", self.events())
        result = self.run_script(FRIGATE_MEDIA_DIR=str(self.root / "media/child"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must match the configured dedicated mountpoint", result.stdout)

    def test_wrong_mounted_device_or_filesystem_stops_before_changes(self):
        other_device = self.root / "other-device"
        other_device.touch()
        result = self.run_script(TEST_MOUNT_SOURCE=str(other_device))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Wrong filesystem mounted", result.stdout)
        self.assertNotIn("chown", self.events())
        result = self.run_script(TEST_MOUNT_FSTYPE="ext4")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Wrong Frigate filesystem type", result.stdout)
        self.assertNotIn("chown", self.events())

    def test_ct_status_query_failure_is_clear_and_stops_early(self):
        result = self.run_script(STATUS_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not determine CT 200 status", result.stdout)
        self.assertNotIn("chown", self.events())
        result = self.run_script(CT_STATUS="stopped")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be running", result.stdout)
        self.assertNotIn("chown", self.events())

    def test_invalid_option_is_rejected(self):
        result = self.run_script("--not-a-real-option")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown argument", result.stdout)
        self.assertNotIn("pct create", self.events())

    def test_existing_setup_is_never_overwritten(self):
        (self.root / "existing").touch()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("will not overwrite", result.stdout)
        self.assertNotIn("chown", self.events())
        self.assertNotIn("pct push", self.events())

    def test_install_only_changes_managed_directories_not_existing_media_files(self):
        existing = self.root / "media/clips/keep.bin"
        existing.write_text("keep")
        existing.chmod(0o640)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(existing.read_text(), "keep")
        self.assertEqual(existing.stat().st_mode & 0o777, 0o640)
        self.assertEqual(existing.stat().st_uid, os.getuid())
        for name in ("clips", "clips/thumbs", "recordings", "snapshots", "exports"):
            path = self.root / "media" / name
            self.assertIn(f"chown 100000:100000 {path}", self.events())
            self.assertEqual(path.stat().st_mode & 0o777, 0o775)
        self.assertNotIn("chown -R", (self.root / "scripts/step04-frigate-deploy.sh").read_text())
        self.assertNotIn("chmod -R", (self.root / "scripts/step04-frigate-deploy.sh").read_text())


if __name__ == "__main__":
    unittest.main()
