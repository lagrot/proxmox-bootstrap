"""Offline fingerprints for Landet recovery; never prints configuration contents."""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

ROOTS = ('etc/landet', 'etc/nginx', 'etc/systemd/system/landet.service',
         'etc/systemd/system/landet-relay.service', 'opt/landet',
         'var/lib/landet-deploy', 'etc/passwd', 'etc/group',
         'etc/apt/apt.conf.d/99-landet-manual-updates')


def fingerprint(root):
    records = {}
    for name in ROOTS:
        start = root / name
        if not start.exists():
            raise ValueError(f'Missing recovery path: {name}')
        paths = [start]
        if start.is_dir():
            paths += sorted(start.rglob('*'))
        for path in paths:
            info = path.lstat()
            record = {'mode': stat.S_IMODE(info.st_mode)}
            if path.is_symlink():
                record['link'] = os.readlink(path)
            elif path.is_file():
                record['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
            elif not path.is_dir():
                raise ValueError('Unexpected special file in recovery configuration')
            records[str(path.relative_to(root))] = record
    if records['etc/landet/viewer.env']['mode'] != 0o600:
        raise ValueError('viewer.env must be mode 0600')
    if records['etc/landet/relay.json']['mode'] != 0o640:
        raise ValueError('relay.json must be mode 0640')
    return {'schema_version': 1, 'ct_id': 240, 'files': records}


def main():
    mode, root, *args = sys.argv[1:]
    result = fingerprint(Path(root))
    if mode == 'capture' and not args:
        print(json.dumps(result, sort_keys=True, indent=2))
    elif mode == 'verify' and len(args) == 1:
        expected = json.loads(Path(args[0]).read_text())
        if result != expected:
            raise ValueError('Restored configuration, release or permissions differ from backup')
        print('Landet configuration, secrets, releases and permissions match')
    else:
        raise ValueError('Usage: capture ROOT | verify ROOT MANIFEST')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print(f'Recovery verification failed: {error}', file=sys.stderr)
        sys.exit(1)
