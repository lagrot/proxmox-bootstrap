import importlib.util
from pathlib import Path
import time,unittest,jwt
from cryptography.hazmat.primitives.asymmetric import rsa
spec=importlib.util.spec_from_file_location('guard',Path(__file__).parents[1]/'proof/access.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Tokens(unittest.TestCase):
 def setUp(self):
  self.private=rsa.generate_private_key(public_exponent=65537,key_size=2048)
  self.guard=m.AccessGuard('https://example.cloudflareaccess.com','a'*64,'owner@example.com')
  self.guard.keys={'known':self.private.public_key()};self.guard.expires=time.monotonic()+300
 def token(self,**changes):
  claims=dict(iss=self.guard.issuer,aud=[self.guard.audience],email=self.guard.email,type='app',sub='owner',iat=int(time.time())-2,exp=int(time.time())+300)
  claims.update(changes);return jwt.encode(claims,self.private,algorithm='RS256',headers={'kid':'known'})
 def test_valid_owner(self):self.assertTrue(self.guard.allows(self.token()))
 def test_wrong_claims(self):
  for claim in [dict(aud=['b'*64]),dict(iss='https://evil.example'),dict(email='other@example.com'),dict(exp=1),dict(iat=int(time.time())+3600),dict(type='org'),dict(sub='')]:
   self.assertFalse(self.guard.allows(self.token(**claim)),claim)
 def test_unsigned_wrong_key_and_malformed(self):
  for token in [None,'bad','x'*16385,jwt.encode({'email':'owner@example.com'},'fake',algorithm='HS256',headers={'kid':'known'}),jwt.encode({'email':'owner@example.com'},None,algorithm='none')]:self.assertFalse(self.guard.allows(token))
  other=rsa.generate_private_key(public_exponent=65537,key_size=2048)
  self.assertFalse(self.guard.allows(jwt.encode({'email':'owner@example.com'},other,algorithm='RS256',headers={'kid':'known'})))
 def test_key_outage_fails_closed_and_is_bounded(self):
  count=[]
  def fail():count.append(1);raise OSError('offline')
  self.guard.refresh=fail;self.guard.expires=0
  self.assertFalse(self.guard.allows(self.token()));self.assertFalse(self.guard.allows(self.token()));self.assertEqual(len(count),1)
 def test_configuration_rejected(self):
  for issuer in ['http://example.cloudflareaccess.com','https://evil.example','https://example.cloudflareaccess.com/path']:
   with self.assertRaises(ValueError):m.AccessGuard(issuer,'a'*64,'owner@example.com')
if __name__=='__main__':unittest.main(verbosity=2)
