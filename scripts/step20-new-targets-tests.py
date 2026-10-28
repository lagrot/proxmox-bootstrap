#!/usr/bin/env python3
"""Exercise the actual updater in an isolated tree with fake Proxmox tools."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/python3
import json, os, pathlib, sys
name=pathlib.Path(sys.argv[0]).name; a=sys.argv[1:]
root=pathlib.Path(os.environ['TEST_ROOT'])
with (root/'events').open('a') as f: f.write(json.dumps([name,*a])+'\n')
if name in ('sleep','flock'): sys.exit(0)
if name=='pvesh': print(json.dumps({'hasFeature':0 if os.getenv('NO_SNAPSHOT') else 1})); sys.exit(0)
if name=='pvesm': print('local-lvm lvmthin active 1000000 100 999900 1%'); sys.exit(0)
if name!='pct': sys.exit(99)
cmd=a[0]
if cmd=='config':
 host='remote-gateway' if a[1]=='230' else 'landet-viewer'
 if os.getenv('BAD_ID'): host='unrelated'
 print(f'hostname: {host}\nunprivileged: 1\nrootfs: local-lvm:vm-{a[1]}-disk-0,size=8G')
elif cmd=='status': print('status: stopped' if (root/'stopped').exists() else 'status: running')
elif cmd=='shutdown': (root/'stopped').touch()
elif cmd=='start': (root/'stopped').unlink(missing_ok=True)
elif cmd=='snapshot':
 if os.getenv('FAIL_SNAPSHOT'): sys.exit(1)
 (root/'snapshot').write_text(a[2])
elif cmd=='listsnapshot':
 print('-> baseline')
 if (root/'snapshot').exists(): print('-> '+(root/'snapshot').read_text())
 print('-> current')
elif cmd=='delsnapshot': (root/'snapshot').unlink()
elif cmd=='exec':
 b=a[3:]
 if b[:2]==['apt-get','update']: sys.exit(1 if os.getenv('FAIL_REFRESH') else 0)
 if b[0]=='unattended-upgrade':
  if '--dry-run' in b: print('Packages that will be upgraded: '+('' if os.getenv('NO_UPDATES') else 'openssl'))
  else:
   if os.getenv('ASSERT_PROGRESS'):
    state=(pathlib.Path(os.environ['SECURITY_UPDATE_STATE_DIR'])/('ct'+a[1]+'.state')).read_text()
    if 'result=installing\n' not in state or 'stage=security-update\n' not in state: sys.exit(98)
   sys.exit(1 if os.getenv('FAIL_INSTALL') else 0)
 elif b[0]=='test': sys.exit(1)
 elif b[0]=='systemctl':
  if 'is-active' in b:
   if 'apt-daily.service' in b: sys.exit(1)
   if os.getenv('BACKEND_DOWN') and 'landet.service' in b and 'nginx.service' not in b: sys.exit(1)
   ready=root/'ready-count'; n=int(ready.read_text())+1 if ready.exists() else 1; ready.write_text(str(n))
   sys.exit(1 if os.getenv('SERVICES_DOWN') or (os.getenv('DELAY_READY') and n<3) else 0)
 else: sys.exit(99)
else: sys.exit(99)
'''
BASELINE = r'''#!/usr/bin/python3
import json, os, pathlib, sys
root=pathlib.Path(os.environ['TEST_ROOT'])
with (root/'events').open('a') as f: f.write(json.dumps(['baseline',sys.argv[1]])+'\n')
p=root/'baseline-count'; n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n))
threshold=int(os.getenv('FAIL_BASELINE_AT','0'))
sys.exit(1 if threshold and n>=threshold else 0)
'''


class WorkflowTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
  self.root=Path(self.tmp.name)
  for name in ('scripts','lib','config','bin','locks'): (self.root/name).mkdir()
  for name in ('common.sh','logging.sh'): shutil.copy(REPO/'lib'/name,self.root/'lib'/name)
  shutil.copy(REPO/'config/defaults.conf',self.root/'config/defaults.conf')
  code=(REPO/'scripts/step20-update-ct.sh').read_text().replace('/run/lock/',str(self.root/'locks')+'/')
  (self.root/'scripts/step20-update-ct.sh').write_text(code)
  (self.root/'scripts/step20c-post-update-validation.sh').write_text("python3 - \"$@\" <<'PYBASE'\n"+BASELINE+"\nPYBASE\n")
  (self.root/'scripts/step20g-unattended-upgrades-validation.sh').write_text('exit 0\n')
  for name in ('pct','pvesh','pvesm','sleep','flock'):
   path=self.root/'bin'/name; path.write_text(FAKE); path.chmod(0o755)
  self.env=dict(os.environ, TEST_ROOT=str(self.root),PATH=str(self.root/'bin')+':'+os.environ['PATH'],
                SECURITY_UPDATE_STATE_DIR=str(self.root/'state'),LOG_FILE=str(self.root/'log'))

 def run_update(self,target,mode,**extra):
  return subprocess.run(['bash',str(self.root/'scripts/step20-update-ct.sh'),target,mode],env=dict(self.env,**extra),capture_output=True,text=True)

 def events(self):
  return [json.loads(line) for line in (self.root/'events').read_text().splitlines()]

 def test_preview_never_stops_or_installs_on_either_target(self):
  for target in ('ct230','ct240'):
   r=self.run_update(target,'--dry-run'); self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  for event in self.events():
   self.assertNotIn(event[1] if len(event)>1 else '',('snapshot','shutdown','start','rollback','delsnapshot'))
   self.assertFalse(event[0]=='pct' and 'unattended-upgrade' in event and '--dry-run' not in event)
   self.assertFalse(event[0]=='pct' and 'systemctl' in event and 'stop' in event)

 def test_success_snapshot_precedes_install_and_cleanup_waits(self):
  for target in ('ct230','ct240'):
   (self.root/'snapshot').unlink(missing_ok=True)
   r=self.run_update(target,'--confirm'); self.assertEqual(r.returncode,0,r.stdout+r.stderr)
   state=(self.root/'state'/f'{target}.state').read_text(); self.assertIn('result=success',state)
   r=self.run_update(target,'--cleanup'); self.assertNotEqual(r.returncode,0); self.assertIn('wait 24 hours',r.stdout)
  events=self.events()
  first_snapshot=next(i for i,e in enumerate(events) if e[0]=='pct' and e[1]=='snapshot')
  first_install=next(i for i,e in enumerate(events) if e[0]=='pct' and 'unattended-upgrade' in e and '--dry-run' not in e)
  self.assertLess(first_snapshot,first_install)

 def test_install_failure_retains_snapshot_without_automatic_rollback(self):
  r=self.run_update('ct230','--confirm',FAIL_INSTALL='1'); self.assertNotEqual(r.returncode,0)
  self.assertTrue((self.root/'snapshot').exists())
  self.assertIn('result=failed',(self.root/'state/ct230.state').read_text())
  self.assertFalse(any(e[0]=='pct' and e[1]=='rollback' for e in self.events()))
  self.assertTrue(any('apt-daily.timer' in e and 'start' in e for e in self.events()))

 def test_each_viewer_service_must_be_active(self):
  r=self.run_update('ct240','--confirm',BACKEND_DOWN='1')
  self.assertNotEqual(r.returncode,0)
  self.assertFalse((self.root/'snapshot').exists())
  self.assertFalse((self.root/'baseline-count').exists())

 def test_install_progress_is_persisted_before_package_engine(self):
  r=self.run_update('ct230','--confirm',ASSERT_PROGRESS='1')
  self.assertEqual(r.returncode,0,r.stdout+r.stderr)

 def test_delayed_service_readiness_is_waited_for(self):
  r=self.run_update('ct230','--confirm',DELAY_READY='1')
  self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  self.assertGreaterEqual(int((self.root/'ready-count').read_text()),3)

 def test_preinstall_failure_can_resume_without_second_shutdown(self):
  r=self.run_update('ct230','--confirm',FAIL_BASELINE_AT='2'); self.assertNotEqual(r.returncode,0)
  snapshot=(self.root/'snapshot').read_text()
  r=self.run_update('ct230','--confirm'); self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  self.assertEqual((self.root/'snapshot').read_text(),snapshot)
  self.assertEqual(sum(e[:2]==['pct','shutdown'] for e in self.events()),1)
  self.assertIn('result=success',(self.root/'state/ct230.state').read_text())

 def test_failed_install_is_never_automatically_resumed(self):
  r=self.run_update('ct240','--confirm',FAIL_INSTALL='1'); self.assertNotEqual(r.returncode,0)
  r=self.run_update('ct240','--confirm'); self.assertNotEqual(r.returncode,0)
  self.assertEqual(sum(e[0]=='pct' and 'unattended-upgrade' in e and '--dry-run' not in e for e in self.events()),1)

 def test_snapshot_failure_restarts_guest_without_installing(self):
  r=self.run_update('ct230','--confirm',FAIL_SNAPSHOT='1'); self.assertNotEqual(r.returncode,0)
  self.assertFalse((self.root/'stopped').exists())
  self.assertFalse(any(e[0]=='pct' and 'unattended-upgrade' in e and '--dry-run' not in e for e in self.events()))

 def test_missing_snapshot_capability_blocks_update(self):
  r=self.run_update('ct240','--confirm',NO_SNAPSHOT='1'); self.assertNotEqual(r.returncode,0)
  self.assertFalse((self.root/'snapshot').exists())

 def test_failure_after_restart_keeps_snapshot_and_never_installs(self):
  r=self.run_update('ct240','--confirm',FAIL_BASELINE_AT='2'); self.assertNotEqual(r.returncode,0)
  self.assertTrue((self.root/'snapshot').exists())
  self.assertIn('stage=post-protection-baseline',(self.root/'state/ct240.state').read_text())
  self.assertFalse(any(e[0]=='pct' and 'unattended-upgrade' in e and '--dry-run' not in e for e in self.events()))

 def test_post_update_validation_failure_retains_protection(self):
  r=self.run_update('ct240','--confirm',FAIL_BASELINE_AT='3'); self.assertNotEqual(r.returncode,0)
  self.assertIn('stage=final-validation',(self.root/'state/ct240.state').read_text())
  self.assertTrue((self.root/'snapshot').exists())
  r=self.run_update('ct240','--cleanup'); self.assertNotEqual(r.returncode,0)
  self.assertTrue((self.root/'snapshot').exists())

 def test_cleanup_after_observation_removes_only_managed_snapshot(self):
  r=self.run_update('ct240','--confirm'); self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  r=self.run_update('ct240','--cleanup',SECURITY_UPDATE_SNAPSHOT_MIN_AGE_SECONDS='0')
  self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  self.assertFalse((self.root/'snapshot').exists())
  self.assertFalse((self.root/'state/ct240.state').exists())

 def test_no_updates_skips_baseline_snapshot_and_restart(self):
  r=self.run_update('ct240','--confirm',NO_UPDATES='1'); self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  self.assertFalse((self.root/'snapshot').exists()); self.assertFalse((self.root/'baseline-count').exists())

 def test_bad_identity_rejected(self):
  r=self.run_update('ct240','--confirm',BAD_ID='1'); self.assertNotEqual(r.returncode,0)
  self.assertFalse((self.root/'snapshot').exists())

 def test_refresh_failure_never_snapshots(self):
  r=self.run_update('ct230','--confirm',FAIL_REFRESH='1'); self.assertNotEqual(r.returncode,0)
  self.assertFalse((self.root/'snapshot').exists())

 def test_failed_baseline_never_installs(self):
  r=self.run_update('ct240','--confirm',FAIL_BASELINE_AT='1'); self.assertNotEqual(r.returncode,0)
  self.assertFalse((self.root/'snapshot').exists())

 def test_orphan_security_snapshot_blocks_update(self):
  (self.root/'snapshot').write_text('pbsec-old-ct230')
  r=self.run_update('ct230','--confirm'); self.assertNotEqual(r.returncode,0)
  self.assertIn('retained security snapshot',r.stdout)

if __name__=='__main__': unittest.main()
