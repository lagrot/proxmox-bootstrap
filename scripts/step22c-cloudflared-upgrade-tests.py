#!/usr/bin/env python3
"""Exercise upgrade orchestration with isolated fake Proxmox commands."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MOCK = '''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
a=sys.argv[1:]
p=pathlib.Path(os.environ['TEST_STATE'])
s=json.loads(p.read_text())
s['calls'].append(a)
rc=0
if a[0]=='status': print('status: running')
elif a[0]=='config': print('hostname: remote-gateway')
elif a[0]=='snapshot': rc=1 if s['fail']=='snapshot' else 0
elif a[0]=='rollback': s['version']='2026.8.3'
elif a[0]=='exec':
 c=a[3:]
 if c[:2]==['env','LC_ALL=C']: c=c[2:]
 if c[0]=='dpkg-query': print(s['version'],end='')
 elif c[0]=='dpkg': rc=subprocess.run(c).returncode
 elif c[:2]==['apt-cache','policy']: print('  Candidate: '+s['candidate'])
 elif c[:2]==['apt-cache','madison']:
  print('cloudflared | '+s['candidate']+' | https://'+('example.com' if s['fail']=='origin' else 'pkg.cloudflare.com')+'/cloudflared any/main amd64 Packages')
 elif c[:2]==['apt-get','update']: rc=1 if s['fail']=='refresh' else 0
 elif '--simulate' in c: rc=1 if s['fail']=='simulate' else 0
 elif c[0]=='env':
  if s['fail']=='install': rc=1
  else: s['version']=s['candidate']
p.write_text(json.dumps(s))
sys.exit(rc)
'''


def case(mode, fail='', version='2026.8.3', candidate='2026.10.4'):
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp)
        for folder in ('scripts', 'lib', 'config', 'bin'):
            (p / folder).mkdir()
        for file in ('lib/common.sh', 'lib/logging.sh', 'config/defaults.conf'):
            shutil.copy(ROOT / file, p / file)
        script = (ROOT / 'scripts/step22c-cloudflared-upgrade.sh').read_text()
        (p / 'scripts/upgrade.sh').write_text(script.replace('/run/lock/', str(p) + '/'))
        for file in ('step22-cloudflare-gateway-validation.sh',
                     'step22a-cloudflare-access-validation.sh',
                     'step22b-cloudflare-homeassistant-validation.sh'):
            (p / 'scripts' / file).write_text(
                '[[ "${TEST_FAIL}" != validation || "$(cat "${TEST_VALIDATE_MARKER}")" == done ]] || '
                '{ echo done >"${TEST_VALIDATE_MARKER}"; exit 1; }\n'
                'if [[ "${TEST_FAIL}" == postvalidation ]]; then\n'
                '  count="$(cat "${TEST_VALIDATE_MARKER}")"; count=${count:-0}\n'
                '  echo "$((count+1))" >"${TEST_VALIDATE_MARKER}"\n'
                '  [[ "$count" != 3 ]] || exit 1\n'
                'fi\n')
        (p / 'bin/pct').write_text(MOCK)
        (p / 'bin/pct').chmod(0o755)
        (p / 'bin/sleep').write_text('#!/bin/sh\nexit 0\n')
        (p / 'bin/sleep').chmod(0o755)
        state = p / 'state.json'
        state.write_text(json.dumps(dict(version=version, candidate=candidate, fail=fail, calls=[])))
        marker = p / 'validated'
        marker.write_text('')
        env = dict(os.environ, PATH=str(p / 'bin') + ':' + os.environ['PATH'],
                   TEST_STATE=str(state), LOG_FILE=str(p / 'test.log'),
                   TEST_FAIL=fail, TEST_VALIDATE_MARKER=str(marker))
        result = subprocess.run(['bash', str(p / 'scripts/upgrade.sh'), mode],
                                env=env, capture_output=True, text=True)
        state = json.loads(state.read_text())
        calls = state['calls']
        if fail or mode == '--invalid':
            assert result.returncode != 0, result.stdout + result.stderr
        else:
            assert result.returncode == 0, result.stdout + result.stderr
        installed = any(c[0] == 'exec' and 'DEBIAN_FRONTEND=noninteractive' in c for c in calls)
        rollback = any(c[0] == 'rollback' for c in calls)
        if mode == '--dry-run':
            assert all(c[0] not in ('snapshot', 'stop', 'rollback', 'start') for c in calls)
            assert not any('apt-get' in c for c in calls)
        if fail in ('simulate', 'refresh', 'origin', 'candidate', 'validation'):
            assert not any(c[0] == 'snapshot' for c in calls)
        if mode != '--apply' or version == '2026.10.4' or fail in ('simulate', 'snapshot', 'validation', 'refresh', 'origin', 'candidate'):
            assert not installed
        if fail in ('install', 'postvalidation'):
            assert rollback and state['version'] == '2026.8.3'
        else:
            assert not rollback
        if mode == '--apply' and not fail and version == '2026.8.3':
            assert installed and state['version'] == candidate
            assert any('--simulate' in c and 'cloudflared=' + candidate in c for c in calls)
            assert any('DEBIAN_FRONTEND=noninteractive' in c and 'cloudflared=' + candidate in c for c in calls)
            assert next(i for i, c in enumerate(calls) if c[0] == 'snapshot') < next(
                i for i, c in enumerate(calls) if c[0] == 'exec' and 'DEBIAN_FRONTEND=noninteractive' in c)


for args in [('--dry-run',), ('--invalid',), ('--apply',),
             ('--apply', 'simulate'), ('--apply', 'snapshot'),
             ('--apply', 'install'), ('--apply', 'validation'),
             ('--apply', 'postvalidation'), ('--apply', '', '2026.10.4'),
             ('--apply', '', '2026.10.5'),
             ('--apply', '', '2026.8.3', '2026.11.1'),
             ('--apply', 'refresh'), ('--apply', 'origin'),
             ('--apply', 'candidate', '2026.8.3', '(none)'),
             ('--dry-run', 'candidate', '2026.8.3', '2026.11.0-rc1')]:
    case(*args)
print('15 isolated upgrade workflow checks passed')
