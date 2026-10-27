import importlib.util,json,os,unittest
from pathlib import Path
from unittest.mock import patch
from io import BytesIO
spec=importlib.util.spec_from_file_location('setup',Path(__file__).parents[2]/'lib/landet_access_setup.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Preview(unittest.TestCase):
 def test_dry_run_has_only_gets_and_no_state_writes(self):
  calls=[]
  def api(req,**kwargs):
   calls.append(req.get_method());self.assertEqual(req.get_method(),'GET')
   path=req.full_url.split('/accounts/test',1)[1]
   if path=='/access/apps?per_page=100':result=[{'id':'ha','domain':'ha.ostmarken.se','allowed_idps':['otp']}]
   elif path=='/access/apps/ha/policies?per_page=100':result=[{'decision':'allow','include':[{'email':{'email':'owner@example.com'}}],'require':[{'login_method':{'id':'otp'}}],'exclude':[]}]
   elif path=='/access/organizations':result={'auth_domain':'example.cloudflareaccess.com'}
   else:self.fail('Unexpected endpoint')
   return BytesIO(json.dumps({'success':True,'result':result}).encode())
  with patch.dict(os.environ,{'CLOUDFLARE_ACCOUNT_ID':'test','CLOUDFLARE_API_TOKEN':'TEST-ONLY'}),patch.object(m.urllib.request,'urlopen',side_effect=api),patch.object(Path,'write_text',side_effect=AssertionError('No writes')),patch.object(Path,'mkdir',side_effect=AssertionError('No directories')):
   m.main('--dry-run')
  self.assertEqual(calls,['GET','GET','GET'])
 def test_bad_mode_performs_no_network(self):
  with patch.object(m.urllib.request,'urlopen') as api:
   with self.assertRaises(ValueError):m.main('--unknown')
   api.assert_not_called()
if __name__=='__main__':unittest.main(verbosity=2)
