#!/usr/bin/env python3
"""Stream a consistent snapshot of a live Frigate SQLite database."""
import os
import sqlite3
import sys
import tempfile
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit('usage: frigate-sqlite-snapshot.py DATABASE')
source = Path(sys.argv[1])
if not source.is_file():
    raise SystemExit('Frigate database is missing')
fd, name = tempfile.mkstemp(prefix='frigate-sqlite-', suffix='.db')
os.close(fd)
try:
    with sqlite3.connect(source.resolve().as_uri() + '?mode=ro', uri=True, timeout=30) as src:
        with sqlite3.connect(name) as dst:
            src.backup(dst, pages=256, sleep=0.1)
            if dst.execute('PRAGMA integrity_check').fetchone() != ('ok',):
                raise RuntimeError('SQLite snapshot integrity check failed')
    with open(name, 'rb') as snapshot:
        while chunk := snapshot.read(1024 * 1024):
            sys.stdout.buffer.write(chunk)
finally:
    os.unlink(name)
