#!/usr/bin/env python3
"""Test Step 04B storage and write-check safeguards with fake Proxmox commands."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class FrigateValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("scripts", "config", "lib", "bin", "media"):
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
        shutil.copy(REPO / "scripts/step04b-frigate-validation.sh",
                    self.root / "scripts/step04b-frigate-validation.sh")
        (self.root / "mounted").touch()
        (self.root / "media/.validation-write-test").write_text("pre-existing sentinel")
        fake = r'''#!/bin/bash
name=$(basename "$0")
case "$name" in
  findmnt)
    [[ -f "$MOUNTED" ]] || exit 1
    if [[ "$1" == -n ]]; then printf '%s %s\n' "$TEST_MOUNT_SOURCE" "$TEST_MOUNT_FSTYPE"; fi ;;
  pct)
    case "$1" in
      config)
        if [[ -f "$BAD_BIND" ]]; then echo 'mp0: /wrong,mp=/wrong';
        else echo "mp0: $MOUNTPOINT,mp=$MEDIA_DIR"; fi ;;
      status)
        [[ "${STATUS_FAIL:-0}" != 1 ]] || exit 1
        printf 'status: %s\n' "${CT_STATUS:-running}" ;;
      exec)
        shift 3
        case "$*" in
          'bash -c command -v '*|systemctl\ is-active*|docker\ compose\ version|docker\ version) exit 0 ;;
          'test -f '*) exit 0 ;;
          'test -d '*) exit 0 ;;
          'test -e '*) exit 0 ;;
          'mktemp '*)
            [[ ! -f "$NO_WRITE" ]] || exit 1
            file=$(mktemp "$TEST_MEDIA/.step04b-write-test.XXXXXX") || exit 1
            echo "$file" ;;
          'rm -f '*) [[ ! -f "$NO_REMOVE" ]] || exit 1; rm -f "${*: -1}" ;;
          'lsusb') echo 'Bus 001 Device 002: ID 1a6e:089a Coral' ;;
          'docker ps '*) echo frigate ;;
          *Health*) echo healthy ;;
          *StartedAt*) echo '2026-11-17T12:00:00Z' ;;
          'curl '*) echo 200 ;;
          'docker logs '*) printf '%s\n' 'Attempting to load TPU as usb' 'TPU found' ;;
          'hostname -I') echo '192.0.2.20' ;;
          *) exit 0 ;;
        esac ;;
    esac ;;
esac
'''
        for name in ("pct", "findmnt"):
            path = self.root / "bin" / name
            path.write_text(fake)
            path.chmod(0o755)
        media = str(self.root / "media")
        self.env = dict(os.environ, PATH=str(self.root / "bin") + ":" + os.environ["PATH"],
                        MOUNTED=str(self.root / "mounted"), BAD_BIND=str(self.root / "bad-bind"),
                        NO_WRITE=str(self.root / "no-write"), NO_REMOVE=str(self.root / "no-remove"), TEST_MEDIA=media,
                        TEST_MOUNT_SOURCE=str(device), TEST_MOUNT_FSTYPE="xfs",
                        STATUS_FAIL="0", CT_STATUS="running",
                        MOUNTPOINT=media, MEDIA_DIR=media,
                        FRIGATE_MEDIA_DIR=media, LOG_FILE=str(self.root / "operation.log"))

    def run_script(self, **extra):
        return subprocess.run(["bash", str(self.root / "scripts/step04b-frigate-validation.sh")],
                              env=dict(self.env, **extra), text=True, capture_output=True)

    def test_success_uses_unique_write_file_and_preserves_old_fixed_name(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Dedicated Frigate device and xfs filesystem verified", result.stdout)
        self.assertIn("binds", result.stdout)
        self.assertIn("unique test file removed", result.stdout)
        self.assertEqual((self.root / "media/.validation-write-test").read_text(),
                         "pre-existing sentinel")
        self.assertEqual(list((self.root / "media").glob(".step04b-write-test.*")), [])

    def test_missing_host_mount_stops_validation(self):
        (self.root / "mounted").unlink()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not mounted on the Proxmox host", result.stdout)
        self.assertNotIn("Checking useful commands", result.stdout)

    def test_wrong_bind_mount_stops_validation(self):
        (self.root / "bad-bind").touch()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not have the expected Frigate SSD bind mount", result.stdout)
        self.assertNotIn("Checking useful commands", result.stdout)

    def test_wrong_media_device_or_filesystem_is_rejected(self):
        other_device = self.root / "other-device"
        other_device.touch()
        result = self.run_script(TEST_MOUNT_SOURCE=str(other_device))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Wrong filesystem mounted", result.stdout)
        self.assertNotIn("Checking useful commands", result.stdout)
        result = self.run_script(TEST_MOUNT_FSTYPE="ext4")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Wrong Frigate filesystem type", result.stdout)

    def test_ct_status_failure_and_stopped_ct_are_distinguished(self):
        result = self.run_script(STATUS_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not determine CT 200 status", result.stdout)
        result = self.run_script(CT_STATUS="stopped")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not running (reported: status: stopped)", result.stdout)

    def test_write_failure_is_reported(self):
        (self.root / "no-write").touch()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot write to", result.stdout)

    def test_cleanup_failure_is_reported_with_temporary_path(self):
        (self.root / "no-remove").touch()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("created ", result.stdout)
        self.assertIn("but could not remove it", result.stdout)


if __name__ == "__main__":
    unittest.main()
