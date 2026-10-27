import sys,os,json,threading,time,unittest
from pathlib import Path
from unittest.mock import patch
from urllib.request import urlopen,Request
from urllib.error import HTTPError
sys.path.insert(0,str(Path(__file__).parents[1]/'proof'))
from server import Server
from access import AccessGuard
import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
class Fake:
 def climate(self):return {'temperature':10}
class Boundary(unittest.TestCase):
 def test_actual_http_requires_signed_owner_token(self):
  private=rsa.generate_private_key(public_exponent=65537,key_size=2048)
  guard=AccessGuard('https://example.cloudflareaccess.com','a'*64,'owner@example.com')
  guard.keys={'known':private.public_key()};guard.expires=time.monotonic()+300
  with patch.dict(os.environ,{'LANDET_MODE':'access','LANDET_ACCESS_ISSUER':guard.issuer,'LANDET_ACCESS_AUD':guard.audience,'LANDET_OWNER_EMAIL':guard.email}),patch('access.AccessGuard',return_value=guard):
   server=Server(('127.0.0.1',0),Fake())
  thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
  try:
   claims=dict(iss=guard.issuer,aud=[guard.audience],email=guard.email,type='app',sub='owner',iat=int(time.time())-1,exp=int(time.time())+60)
   valid=jwt.encode(claims,private,algorithm='RS256',headers={'kid':'known'})
   wrong=jwt.encode(claims|{'aud':['b'*64]},private,algorithm='RS256',headers={'kid':'known'})
   base='http://127.0.0.1:'+str(server.server_port)
   for token in ['', 'bad', wrong]:
    with self.assertRaises(HTTPError) as e:urlopen(Request(base+'/api/climate',headers={'Cf-Access-Jwt-Assertion':token}),timeout=3)
    self.assertEqual(e.exception.code,401)
   with urlopen(Request(base+'/api/climate',headers={'Cf-Access-Jwt-Assertion':valid,'Origin':'https://landet.ostmarken.se'}),timeout=3) as r:self.assertEqual(json.load(r)['temperature'],10)
   navigation={'Cf-Access-Jwt-Assertion':valid,'Sec-Fetch-Site':'cross-site','Sec-Fetch-Mode':'navigate','Sec-Fetch-Dest':'document'}
   with urlopen(Request(base+'/api/climate',headers=navigation),timeout=3) as r:self.assertEqual(r.status,200)
   image=navigation|{'Sec-Fetch-Mode':'no-cors','Sec-Fetch-Dest':'image'}
   with self.assertRaises(HTTPError) as blocked:urlopen(Request(base+'/api/climate',headers=image),timeout=3)
   self.assertEqual(blocked.exception.code,403)
   with urlopen(base+'/healthz',timeout=3) as r:self.assertEqual(json.load(r)['mode'],'access')
  finally:server.shutdown();server.server_close();thread.join()
if __name__=='__main__':unittest.main(verbosity=2)
