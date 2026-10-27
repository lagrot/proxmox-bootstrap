"""Owner-only Access app preparation, deliberately without DNS/tunnel changes."""
import json,os,sys,urllib.request
from pathlib import Path
HOST='landet.ostmarken.se'
STATE=Path('/var/lib/proxmox-bootstrap/landet/access.json')
NAME='Landet viewer (proxmox-bootstrap)'
def main(mode):
 if mode not in ('--dry-run','--apply'):raise ValueError('Invalid mode')
 account=os.environ['CLOUDFLARE_ACCOUNT_ID'];token=os.environ['CLOUDFLARE_API_TOKEN']
 base='https://api.cloudflare.com/client/v4/accounts/'+account
 def api(method,path,body=None):
  if mode != '--apply' and method != 'GET':raise RuntimeError('Read-only mode forbids API mutations')
  raw=None if body is None else json.dumps(body).encode()
  with urllib.request.urlopen(urllib.request.Request(base+path,data=raw,method=method,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'}),timeout=20) as r:data=json.load(r)
  if not data.get('success'):raise RuntimeError('Cloudflare rejected request')
  return data['result']
 apps=api('GET','/access/apps?per_page=100')
 source=[a for a in apps if a.get('domain')=='ha.ostmarken.se']
 if len(source)!=1:raise RuntimeError('Expected the verified HA Access application')
 ha=source[0];policies=api('GET','/access/apps/'+ha['id']+'/policies?per_page=100')
 if len(policies)!=1:raise RuntimeError('Unexpected HA policy count')
 p=policies[0];ids=ha.get('allowed_idps',[])
 if len(ids)!=1 or p.get('decision')!='allow' or p.get('require')!=[{'login_method':{'id':ids[0]}}] or p.get('exclude'):
  raise RuntimeError('HA owner/OTP baseline differs')
 include=p.get('include',[])
 if len(include)!=1 or set(include[0])!={'email'}:raise RuntimeError('Expected one exact owner email')
 owner=include[0]['email']['email']
 organization=api('GET','/access/organizations');issuer='https://'+organization['auth_domain']
 desired={'name':NAME,'type':'self_hosted','domain':HOST,'destinations':[{'type':'public','uri':HOST}],
          'session_duration':'24h','allowed_idps':ids,'auto_redirect_to_identity':True,
          'app_launcher_visible':False,'allow_authenticate_via_warp':False}
 policy={'name':'Allow owner with OTP','decision':'allow','precedence':1,'include':include,
         'require':[{'login_method':{'id':ids[0]}}],'exclude':[]}
 found=[a for a in apps if a.get('domain')==HOST]
 if len(found)>1:raise RuntimeError('Ambiguous Landet application')
 if mode=='--dry-run':
  print('Would create or verify a separate owner-only OTP Access application (24h).')
  print('No DNS, tunnel route, shared identity-provider or HA application changes.')
  return
 if found:
  app=found[0]
  if any(app.get(k)!=v for k,v in desired.items()):raise RuntimeError('Existing Landet app differs; refusing to overwrite')
 else:app=api('POST','/access/apps',desired)
 path='/access/apps/'+app['id']+'/policies'
 ps=api('GET',path+'?per_page=100')
 if not ps:api('POST',path,policy);ps=api('GET',path+'?per_page=100')
 if len(ps)!=1 or any(ps[0].get(k)!=v for k,v in policy.items()):raise RuntimeError('Landet exact-owner OTP policy mismatch; hostname remains unpublished')
 app=api('GET','/access/apps/'+app['id'])
 STATE.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
 STATE.write_text(json.dumps({'app_id':app['id'],'audience':app['aud'],'issuer':issuer,'owner_email':owner,'hostname':HOST}))
 STATE.chmod(0o600)
 print('Separate Landet Access application and exact-owner OTP policy verified. DNS/tunnel configuration was not changed.')
if __name__=='__main__':
 try:main(sys.argv[1])
 except Exception:sys.exit('Access preparation failed; no DNS/tunnel changes were made. Inspect app/policy consistency.')
