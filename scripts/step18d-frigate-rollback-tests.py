#!/usr/bin/env python3
"""Test Step 18D safety checks and archive validation without Proxmox."""

import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
BACKUP = "/var/lib/frigate-upgrades/20261117-145649-0.17.2-to-0.18.2"


class ArchiveSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.archive = self.root / "backup.tar.gz"
        self.helper = REPO / "lib/frigate-upgrade-archive.py"

    def make_archive(self, entries):
        with tarfile.open(self.archive, "w:gz") as bundle:
            for name, kind in entries:
                info = tarfile.TarInfo(name)
                if kind == "dir":
                    info.type = tarfile.DIRTYPE
                    bundle.addfile(info)
                elif kind == "link":
                    info.type = tarfile.SYMTYPE
                    info.linkname = "../../etc/passwd"
                    bundle.addfile(info)
                else:
                    data = b"test"
                    info.size = len(data)
                    import io
                    bundle.addfile(info, io.BytesIO(data))

    def run_helper(self):
        return subprocess.run(["python3", str(self.helper), str(self.archive),
                                "opt/frigate/docker-compose.yml", "opt/frigate/config"],
                               text=True, capture_output=True)

    def test_accepts_expected_regular_backup_layout(self):
        self.make_archive((
            ("opt/frigate/docker-compose.yml", "file"),
            ("opt/frigate/config", "dir"),
            ("opt/frigate/config/config.yml", "file"),
            ("opt/frigate/config/frigate.db", "file"),
        ))
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_traversal_links_duplicates_and_unrelated_paths(self):
        cases = (
            (("opt/frigate/docker-compose.yml", "file"), ("opt/frigate/config", "dir"),
             ("../etc/cron.d/pwn", "file")),
            (("opt/frigate/docker-compose.yml", "file"), ("opt/frigate/config", "dir"),
             ("opt/frigate/config/escape", "link")),
            (("opt/frigate/docker-compose.yml", "file"), ("opt/frigate/config", "dir"),
             ("etc/shadow", "file")),
            (("opt/frigate/docker-compose.yml", "file"), ("opt/frigate/docker-compose.yml", "file"),
             ("opt/frigate/config", "dir")),
        )
        for entries in cases:
            with self.subTest(entries=entries):
                self.make_archive(entries)
                self.assertNotEqual(self.run_helper().returncode, 0)


class RollbackScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for folder in ("scripts", "lib", "config", "bin"):
            (self.root / folder).mkdir()
        shutil.copy(REPO / "scripts/step18d-frigate-rollback.sh", self.root / "scripts")
        shutil.copy(REPO / "lib/frigate-upgrade-archive.py", self.root / "lib")
        shutil.copy(REPO / "lib/common.sh", self.root / "lib")
        shutil.copy(REPO / "lib/logging.sh", self.root / "lib")
        shutil.copy(REPO / "config/defaults.conf", self.root / "config")
        validator = self.root / "scripts/step18c-frigate-post-upgrade-validation.sh"
        validator.write_text("#!/bin/bash\nexit 0\n")
        validator.chmod(0o755)
        pct = self.root / "bin/pct"
        pct.write_text(r'''#!/bin/bash
printf '%s\n' "$*" >> "$PCT_LOG"
case "$1" in
 status)
   [[ "$STATUS_FAIL" != 1 ]] || { echo 'permission denied' >&2; exit 1; }
   [[ "$STATUS_STOPPED" != 1 ]] && echo 'status: running' || echo 'status: stopped' ;;
 exec)
   shift 3
   case "$1" in
     test) [[ "$TEST_FAIL" != 1 ]] ;;
     bash) [[ "$BACKUP_CHECK_FAIL" != 1 ]] ;;
     grep) exit 0 ;;
     awk)
       case "$*" in
         *OLD_VERSION*) echo 0.17.2 ;;
         *OLD_IMAGE*) echo ghcr.io/blakeblackshear/frigate:0.17.2 ;;
         *TARGET_VERSION*) echo 0.18.2 ;;
         *COMPOSE_FILE*) echo /opt/frigate/docker-compose.yml ;;
         *CONFIG_DIR*) echo /opt/frigate/config ;;
         *image:*) echo ghcr.io/blakeblackshear/frigate:0.17.2 ;;
         *) exit 2 ;;
       esac ;;
     docker)
       [[ "$*" != *'image inspect'* || "$IMAGE_MISSING" != 1 ]] && exit 0 || exit 1 ;;
     python3) echo 'ARCHIVE SAFE' ;;
     mktemp)
       shift
       path=$(mktemp -d "$2") || exit
       echo "$path" ;;
     tar)
       [[ "$FAIL_OP" != tar ]] ;;
     chmod) exit 0 ;;
     mv|cp)
       [[ "$FAIL_OP" != "$1" ]] ;;
     rm) rm -rf -- "$2" ;;
     curl) echo 0.17.2-cfa08c5 ;;
     *) echo "unexpected guest operation: $*" >&2; exit 9 ;;
   esac ;;
 *) exit 2 ;;
esac
''')
        pct.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.root / "bin"}:' + os.environ["PATH"],
                        PCT_LOG=str(self.root / "pct.log"),
                        LOG_FILE=str(self.root / "operation.log"),
                        STATUS_FAIL="0", STATUS_STOPPED="0", TEST_FAIL="0",
                        BACKUP_CHECK_FAIL="0", IMAGE_MISSING="0", FAIL_OP="")

    def run_script(self, *args, **changes):
        return subprocess.run(["bash", str(self.root / "scripts/step18d-frigate-rollback.sh"),
                               "--backup-dir", BACKUP, *args],
                              env=dict(self.env, **changes), text=True, capture_output=True)

    def test_dry_run_validates_and_does_not_mutate(self):
        result = self.run_script("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.root / "pct.log").read_text()
        self.assertNotIn("compose stop", calls)
        self.assertNotIn("compose up", calls)
        self.assertNotIn("mv ", calls)

    def test_restore_test_cleans_only_its_temporary_staging(self):
        result = self.run_script("--restore-test")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.root / "pct.log").read_text()
        self.assertIn("tar -xzf", calls)
        self.assertIn("Production Compose, config, container, database, and media were not changed", result.stdout)
        self.assertRegex(calls, r"rm -rf -- /tmp/frigate-rollback\.[A-Za-z0-9]{10}")
        self.assertNotIn("compose stop", calls)

    def test_invalid_paths_and_duplicate_backup_arg_abort_before_guest_calls(self):
        cases = (
            (("--backup-dir", "/var/lib/frigate-upgrades/../../tmp/evil", "--dry-run"), "managed backup path"),
            (("--backup-dir", BACKUP, "--backup-dir", BACKUP, "--dry-run"), "only be provided once"),
            (("--backup-dir", BACKUP, "--dry-run", "--restore-test"), "Choose exactly one mode"),
        )
        for args, message in cases:
            (self.root / "pct.log").unlink(missing_ok=True)
            result = subprocess.run(["bash", str(self.root / "scripts/step18d-frigate-rollback.sh"), *args],
                                    env=self.env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stdout + result.stderr)
            self.assertFalse((self.root / "pct.log").exists())

    def test_status_and_backup_failures_abort_before_staging(self):
        for changes, message in (({"STATUS_FAIL": "1"}, "Could not query CT 200 status"),
                                 ({"STATUS_STOPPED": "1"}, "CT 200 is not running"),
                                 ({"BACKUP_CHECK_FAIL": "1"}, "Backup integrity validation failed"),
                                 ({"IMAGE_MISSING": "1"}, "Old exact image is not local")):
            with self.subTest(changes=changes):
                (self.root / "pct.log").unlink(missing_ok=True)
                result = self.run_script("--restore-test", **changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stdout + result.stderr)
                self.assertNotIn("mktemp -d", (self.root / "pct.log").read_text())

    def test_interrupted_production_rollback_preserves_staging(self):
        result = self.run_script("--confirm-rollback", FAIL_OP="mv")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("preserve and inspect staging directory", result.stdout)
        calls = (self.root / "pct.log").read_text()
        self.assertIn("stop frigate", calls)
        self.assertNotRegex(calls, r"rm -rf -- /tmp/frigate-rollback\.[A-Za-z0-9]{10}")


if __name__ == "__main__":
    unittest.main()
