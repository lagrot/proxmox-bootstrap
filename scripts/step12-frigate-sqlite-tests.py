#!/usr/bin/env python3
"""Test the SQLite snapshot used by weekly Frigate backups."""
import sqlite3
import subprocess
import tempfile
import unittest
import tarfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'lib/frigate-sqlite-snapshot.py'
VALIDATOR = SCRIPT.parent.parent / 'scripts/step12-backup-validation.sh'


class SnapshotTests(unittest.TestCase):
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
