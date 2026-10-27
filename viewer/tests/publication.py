import copy,importlib.util,json,os,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('publish',Path(__file__).parents[2]/'lib/landet_publish.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Transaction(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
  root=Path(self.temp.name);self.state=patch.object(m,'STATE',root/'publication.json');self.state.start();self.addCleanup(self.state.stop)
  self.access=patch.object(m,'ACCESS',root/'access.json');self.access.start();self.addCleanup(self.access.stop)
  m.ACCESS.write_text(json.dumps({'issuer':'https://example.cloudflareaccess.com','audience':'a'*64,'app_id':'app','owner_email':'owner@example.com'}))
  env={'CLOUDFLARE_ACCOUNT_ID':'account','CLOUDFLARE_API_TOKEN':'TEST-ONLY','CLOUDFLARE_TUNNEL_ID':'tunnel','CLOUDFLARE_ZONE_ID':'zone','LANDET_ORIGIN':'http://192.168.8.124:8080'}
  self.env=patch.dict(os.environ,env);self.env.start();self.addCleanup(self.env.stop)
  self.config={'ingress':[{'hostname':'ha.ostmarken.se','service':'http://private-ha:8123','originRequest':{}},{'service':'http_status:404'}],'warp-routing':{'enabled':False}}
  self.rows=[];self.writes=[]
 def publisher(self,mode):
  p=m.Publisher(mode)
  def api(method,path,body=None):
   if method!='GET':self.writes.append((method,path))
   if path==p.endpoint:
    if method=='PUT':self.config=copy.deepcopy(body['config'])
    return {'config':copy.deepcopy(self.config)}
   if path.startswith(p.dns):
    if method=='POST':self.rows=[body|{'id':'dns'}]
    if method=='DELETE':self.rows=[]
    return copy.deepcopy(self.rows)
   if '/identity_providers/' in path:return {'type':'onetimepin'}
   if '/policies' in path:return [{'decision':'allow','include':[{'email':{'email':'owner@example.com'}}],'require':[{'login_method':{'id':'otp'}}],'exclude':[]}]
   return {'id':'app','domain':m.HOST,'aud':'a'*64,'type':'self_hosted','session_duration':'24h','allow_authenticate_via_warp':False,'auto_redirect_to_identity':True,'allowed_idps':['otp']}
  p.api=api;p.external_denial=lambda:None
  return p
 def test_preview_only_reads_and_writes_no_state(self):
  p=self.publisher('--dry-run');p.run();self.assertFalse(self.writes);self.assertFalse(m.STATE.exists())
 def test_route_test_restores_entire_config_without_dns(self):
  before=copy.deepcopy(self.config);self.publisher('--test-route').run();self.assertEqual(self.config,before);self.assertEqual(self.rows,[])
  self.assertFalse(any(path==self.publisher('--test-route').dns for method,path in self.writes))
 def test_publication_rollback_preserves_concurrent_unrelated_route(self):
  self.publisher('--apply').run();self.assertEqual(len(self.rows),1)
  extra={'hostname':'other.example.com','service':'http://other:8080'};self.config['ingress'].insert(1,extra)
  self.publisher('--rollback').run();self.assertEqual(self.config['ingress'],[extra,{'hostname':'ha.ostmarken.se','service':'http://private-ha:8123','originRequest':{}},{'service':'http_status:404'}]);self.assertFalse(self.rows)
 def test_external_denial_failure_rolls_back(self):
  p=self.publisher('--apply');before=copy.deepcopy(self.config)
  def fail():raise ValueError('denial not proven')
  p.external_denial=fail
  with patch.object(m.time,'sleep'),self.assertRaises(RuntimeError):p.run()
  self.assertEqual(self.config,before);self.assertFalse(self.rows)
 def test_repeat_apply_does_not_mutate(self):
  self.publisher('--apply').run();self.writes=[];self.publisher('--apply').run();self.assertFalse(self.writes)
 def test_conflicting_dns_is_not_overwritten(self):
  self.rows=[{'name':m.HOST,'type':'A','content':'1.2.3.4'}]
  with self.assertRaises(ValueError):self.publisher('--apply').run()
  self.assertFalse(self.writes)
 def test_foreign_route_is_not_changed(self):
  self.config['ingress'].insert(0,{'hostname':m.HOST,'service':'http://other:9999'})
  with self.assertRaises(ValueError):self.publisher('--apply').run()
  self.assertFalse(self.writes)
if __name__=='__main__':unittest.main(verbosity=2)
