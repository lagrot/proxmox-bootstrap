#!/usr/bin/env python3
"""Test the SQLite snapshot used by weekly Frigate backups."""
import sqlite3
import subprocess
import tempfile
import unittest
import tarfile
import os
import shutil
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'lib/frigate-sqlite-snapshot.py'
VALIDATOR = SCRIPT.parent.parent / 'scripts/step12-backup-validation.sh'


class SnapshotTests(unittest.TestCase):
    def test_hermes_archive_failure_restores_previously_active_services(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for directory in ('scripts', 'lib', 'config', 'bin', 'backups', 'fixture/opt/frigate/config'):
                (root / directory).mkdir(parents=True)
            repo = SCRIPT.parent.parent
            for name in ('common.sh', 'logging.sh', 'frigate-sqlite-snapshot.py'):
                shutil.copy(repo / 'lib' / name, root / 'lib' / name)
            shutil.copy(repo / 'scripts/step12-backup.sh', root / 'scripts/step12-backup.sh')
            (root / 'config/defaults.conf').write_text(f'BACKUP_ROOT="{root}/backups"\n')
            (root / 'fixture/opt/frigate/docker-compose.yml').write_text('services: {}\n')
            (root / 'fixture/opt/frigate/config/config.yml').write_text('cameras: {}\n')
            with sqlite3.connect(root / 'fixture/db') as db:
                db.execute('CREATE TABLE events (id INTEGER)')
            (root / 'bin/pct').write_text('''#!/bin/bash
echo "$*" >> "$EVENTS"
if [[ "$1" == status ]]; then echo 'status: running'; exit 0; fi
id="$2"; shift 3
if [[ "$1" == systemctl ]]; then
  if [[ "$2" == is-active && "$*" == *dashboard* && "${DASHBOARD_INACTIVE:-0}" == 1 ]]; then exit 3; fi
  exit 0
fi
if [[ "$id" == 200 && "$1" == tar ]]; then exec tar -C "$FIXTURE" -cf - opt/frigate; fi
if [[ "$id" == 200 && "$1" == python3 ]]; then exec cat "$FIXTURE/db"; fi
if [[ "$id" == 210 && "$1" == tar ]]; then exec tar -C "$FIXTURE" -czf - opt/frigate; fi
if [[ "$id" == 220 && "$1" == tar ]]; then exit 1; fi
exit 1
''')
            for cmd in ('qm', 'vzdump'):
                (root / 'bin' / cmd).write_text('#!/bin/sh\nexit 0\n')
            for executable in (root / 'bin').iterdir():
                executable.chmod(0o755)
            for inactive in ('0', '1'):
                events = root / f'events-{inactive}'
                env = dict(os.environ, PATH=str(root / 'bin') + ':' + os.environ['PATH'],
                           EVENTS=str(events), FIXTURE=str(root / 'fixture'),
                           DASHBOARD_INACTIVE=inactive, BACKUP_LOCK_HELD='1')
                result = subprocess.run(['bash', str(root / 'scripts/step12-backup.sh')], env=env,
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                calls = events.read_text().splitlines()
                self.assertTrue(any('systemctl stop hermes-gateway.service' in c for c in calls))
                self.assertTrue(any('systemctl start hermes-gateway.service' in c for c in calls))
                self.assertEqual(any('systemctl start hermes-dashboard.service' in c for c in calls), inactive == '0')

    def test_wal_data_is_present_and_restorable(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'source.db'
            with sqlite3.connect(source) as db:
                db.execute('PRAGMA journal_mode=WAL')
                db.execute('CREATE TABLE events (id INTEGER PRIMARY KEY, name TEXT)')
                db.execute("INSERT INTO events VALUES (1, 'live')")
                db.commit()
                result = subprocess.run(['python3', str(SCRIPT), str(source)], capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                snapshot = Path(tmp) / 'restore.db'
                snapshot.write_bytes(result.stdout)
                with sqlite3.connect(snapshot) as restored:
                    self.assertEqual(restored.execute('PRAGMA integrity_check').fetchone(), ('ok',))
                    self.assertEqual(restored.execute('SELECT name FROM events').fetchone(), ('live',))

    def test_missing_and_invalid_databases_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ('missing.db', 'invalid.db'):
                path = Path(tmp) / name
                if name == 'invalid.db':
                    path.write_text('not a database')
                result = subprocess.run(['python3', str(SCRIPT), str(path)], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b'')

    def test_backup_validator_accepts_snapshot_and_rejects_corrupt_database(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / 'source/opt/frigate/config'
            config.mkdir(parents=True)
            database = config / 'frigate.db'
            with sqlite3.connect(database) as db:
                db.execute('CREATE TABLE events (id INTEGER)')
            (config / '.backup-sqlite-format').write_text('sqlite-online-backup-v1\n')
            (root / 'dummy').write_text('test')
            (root / 'vzdump-qemu-100-test.vma.zst').write_bytes(b'test')

            def archives():
                with tarfile.open(root / 'frigate.tar.gz', 'w:gz') as archive:
                    archive.add(root / 'source/opt', arcname='opt')
                for name in ('mosquitto', 'hermes'):
                    with tarfile.open(root / f'{name}.tar.gz', 'w:gz') as archive:
                        archive.add(root / 'dummy', arcname=f'{name}-dummy')
                subprocess.run('sha256sum *.tar.gz > SHA256SUMS', cwd=root, shell=True, check=True)

            archives()
            result = subprocess.run(['bash', str(VALIDATOR), str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('Frigate SQLite snapshot integrity verified', result.stdout)
            (root / '.validated').unlink()
            database.write_text('corrupt')
            archives()
            result = subprocess.run(['bash', str(VALIDATOR), str(root)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / '.validated').exists())


if __name__ == '__main__':
    unittest.main()
