"""Narrow Cloudflare publication transaction for the protected Landet viewer."""
import copy,http.client,ipaddress,json,os,re,socket,ssl,subprocess,sys,time,urllib.request,urllib.error
from pathlib import Path
from urllib.parse import urlsplit
HOST='landet.ostmarken.se'
MARKER='Managed Landet viewer - proxmox-bootstrap'
STATE=Path('/var/lib/proxmox-bootstrap/landet/publication.json')
ACCESS=STATE.with_name('access.json')
class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*args):return None

def compose(config,route):
 result=copy.deepcopy(config);rules=result.get('ingress',[])
 if not rules or rules[-1].get('service')!='http_status:404' or 'hostname' in rules[-1]:raise ValueError('Expected safe terminal catch-all')
 matches=[r for r in rules if r.get('hostname')==HOST]
 if len(matches)>1:raise ValueError('Ambiguous Landet routes')
 if matches and matches[0]!=route:raise ValueError('Existing Landet route differs; refusing takeover')
 result['ingress']=[route]+[r for r in rules if r.get('hostname')!=HOST]
 return result

class Publisher:
 def __init__(self,mode):
  self.mode=mode
  self.account=os.environ['CLOUDFLARE_ACCOUNT_ID'];self.token=os.environ['CLOUDFLARE_API_TOKEN']
  self.tunnel=os.environ['CLOUDFLARE_TUNNEL_ID'];self.zone=os.environ['CLOUDFLARE_ZONE_ID']
  self.access=json.loads(ACCESS.read_text())
  issuer=self.access['issuer'];team=urlsplit(issuer).hostname.removesuffix('.cloudflareaccess.com')
  self.route={'hostname':HOST,'service':os.environ['LANDET_ORIGIN'],
   'originRequest':{'access':{'required':True,'teamName':team,'audTag':[self.access['audience']]}}}
  self.endpoint=f'/accounts/{self.account}/cfd_tunnel/{self.tunnel}/configurations'
  self.dns=f'/zones/{self.zone}/dns_records'
 def api(self,method,path,body=None):
  if self.mode in ('--dry-run','--validate') and method!='GET':raise RuntimeError('Read-only mode')
  request=urllib.request.Request('https://api.cloudflare.com/client/v4'+path,method=method,
   data=None if body is None else json.dumps(body).encode(),headers={'Authorization':'Bearer '+self.token,'Content-Type':'application/json'})
  with urllib.request.urlopen(request,timeout=20) as response:data=json.load(response)
  if not data.get('success'):raise RuntimeError('Cloudflare API failure')
  return data['result']
 def records(self):return self.api('GET',self.dns+'?name='+HOST)
 def config(self):return self.api('GET',self.endpoint)['config']
 def policy(self):
  app=self.api('GET',f'/accounts/{self.account}/access/apps/'+self.access['app_id'])
  if (app.get('domain')!=HOST or app.get('aud')!=self.access['audience'] or app.get('type')!='self_hosted'
      or app.get('session_duration')!='24h' or app.get('allow_authenticate_via_warp') is not False
      or app.get('auto_redirect_to_identity') is not True or len(app.get('allowed_idps',[]))!=1):raise ValueError('Access application mismatch')
  idp=app['allowed_idps'][0]
  provider=self.api('GET',f'/accounts/{self.account}/access/identity_providers/'+idp)
  if provider.get('type')!='onetimepin':raise ValueError('OTP identity provider required')
  policies=self.api('GET',f'/accounts/{self.account}/access/apps/'+app['id']+'/policies?per_page=100')
  if len(policies)!=1:raise ValueError('Exactly one owner policy required')
  p=policies[0]
  if (p.get('decision')!='allow' or p.get('include')!=[{'email':{'email':self.access['owner_email']}}]
      or p.get('require')!=[{'login_method':{'id':idp}}] or p.get('exclude')):raise ValueError('Exact-owner OTP policy required')
 def dns_ok(self,row):return row.get('name')==HOST and row.get('type')=='CNAME' and row.get('content')==self.tunnel+'.cfargotunnel.com' and row.get('proxied') is True
 def preflight(self):
  self.policy();config=self.config();desired=compose(config,self.route)
  rows=self.records()
  if len(rows)>1 or (rows and (not self.dns_ok(rows[0]) or rows[0].get('comment')!=MARKER)):raise ValueError('Conflicting or unmanaged DNS record')
  if rows and not STATE.exists():raise ValueError('Missing publication ownership state')
  return config,desired,rows
 def save(self,state):
  STATE.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
  temp=STATE.with_suffix('.tmp');temp.write_text(json.dumps(state));temp.chmod(0o600);temp.replace(STATE)
 def rollback(self):
  if not STATE.exists():raise ValueError('No managed publication state')
  state=json.loads(STATE.read_text())
  if state.get('tunnel')!=self.tunnel or state.get('zone')!=self.zone or state.get('route')!=self.route:raise ValueError('Publication state mismatch')
  # Remove only records proven to belong to this transaction; never restore an
  # old full tunnel config over unrelated concurrent changes.
  rows=self.records()
  for row in rows:
   if not self.dns_ok(row) or row.get('comment')!=MARKER:raise ValueError('DNS ownership changed; refusing deletion')
   self.api('DELETE',self.dns+'/'+row['id'])
  config=self.config();matches=[r for r in config['ingress'] if r.get('hostname')==HOST]
  if any(r!=self.route for r in matches):raise ValueError('Route ownership changed; refusing removal')
  if matches:
   config['ingress']=[r for r in config['ingress'] if r.get('hostname')!=HOST]
   self.api('PUT',self.endpoint,{'config':config})
  state['phase']='rolled-back';self.save(state)
 def external_denial(self):
  # A previous absent name can remain negatively cached at recursive resolvers.
  # Use the zone's authoritative DNS for this probe, then validate TLS against
  # the real hostname (SNI + certificate); never disable certificate verification.
  zone=self.api('GET','/zones/'+self.zone)
  names=zone.get('name_servers',[])
  if not names or not re.fullmatch(r'[a-z0-9-]+\.ns\.cloudflare\.com',names[0]):raise ValueError('Unexpected authoritative DNS')
  output=subprocess.check_output(['dig','+short','A',HOST,'@'+names[0]],timeout=8).decode()
  addresses=[]
  for line in output.splitlines():
   try:
    address=ipaddress.ip_address(line)
    if address.version==4 and address.is_global:addresses.append(str(address))
   except ValueError:pass
  if not addresses:raise ValueError('Authoritative DNS has no public A record yet')
  edge=addresses[0]
  class EdgeConnection(http.client.HTTPSConnection):
   def connect(connection):
    raw=socket.create_connection((edge,443),timeout=10)
    try:connection.sock=ssl.create_default_context().wrap_socket(raw,server_hostname=HOST)
    except Exception:raw.close();raise
  for path in ['/','/api/climate','/api/clips','/api/cameras/c200/live.mp4']:
   connection=EdgeConnection(HOST,timeout=10)
   try:
    connection.request('GET',path,headers={'User-Agent':'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36','Cf-Access-Jwt-Assertion':'forged.invalid.signature'})
    response=connection.getresponse();location=urlsplit(response.getheader('Location',''))
    if response.status not in (302,303,307) or location.scheme!='https' or location.hostname!=urlsplit(self.access['issuer']).hostname:
     raise ValueError('Unauthenticated interception check: HTTP '+str(response.status))
   finally:connection.close()
 def run(self):
  if self.mode=='--rollback':self.rollback();print('Only managed Landet DNS/route removed; Access policy, CT240 and other routes retained.');return
  before,desired,rows=self.preflight()
  if self.mode=='--dry-run':
   print('Verified exact-owner OTP policy, dedicated audience and 24h session.')
   print('Would add only guarded Landet ingress and a managed proxied CNAME; HA routes remain unchanged.')
   return
  if self.mode=='--validate':
   if before!=desired or len(rows)!=1:raise ValueError('Publication not in desired state')
   self.external_denial();print('Guarded ingress, managed DNS, exact-owner policy and external unauthenticated denial pass.');return
  if self.mode not in ('--apply','--test-route'):raise ValueError('Invalid mode')
  if self.mode=='--test-route' and (rows or any(r.get('hostname')==HOST for r in before['ingress'])):raise ValueError('Route-only pilot requires unpublished hostname')
  if self.mode=='--apply' and before==desired and rows:
   self.external_denial();print('Already published correctly; no route/DNS mutation.');return
  state={'tunnel':self.tunnel,'zone':self.zone,'route':self.route,'phase':'planned'}
  self.save(state)
  try:
   if before!=desired:
    # Detect concurrent updates immediately before the whole-config PUT.
    if self.config()!=before:raise ValueError('Tunnel changed during preparation')
    self.api('PUT',self.endpoint,{'config':desired})
   if self.mode=='--test-route':
    if self.config()!=desired:raise ValueError('Pilot route readback mismatch')
    self.rollback()
    if self.config()!=before or self.records():raise ValueError('Route-only rollback mismatch')
    print('Guarded route add/readback/removal tested without DNS; complete original tunnel configuration preserved.');return
   if not rows:self.api('POST',self.dns,{'type':'CNAME','name':HOST,'content':self.tunnel+'.cfargotunnel.com','proxied':True,'ttl':1,'comment':MARKER})
   self.preflight()
   last=None
   for attempt in range(30):
    try:self.external_denial();last=None;break
    except Exception as error:last=error;time.sleep(3)
   if last:raise ValueError('External Access interception did not pass: '+(str(last) if type(last) is ValueError else type(last).__name__)) from last
   state['phase']='published';self.save(state)
   print('Published https://'+HOST+'; external unauthenticated denial passes. Owner browser acceptance remains.')
  except Exception as original:
   try:self.rollback()
   except Exception:raise RuntimeError('Publication failed and rollback could not be verified; keep Access enabled and inspect the managed state')
   reason=str(original) if type(original) is ValueError else type(original).__name__
   raise RuntimeError('Publication failed; managed Landet route/DNS rolled back. Check: '+reason) from original

def main():
 if len(sys.argv)!=2 or sys.argv[1] not in ('--dry-run','--apply','--validate','--rollback','--test-route'):raise ValueError('Invalid mode')
 Publisher(sys.argv[1]).run()
if __name__=='__main__':
 try:main()
 except Exception as error:
  # Only our own fixed diagnostic messages; never dump upstream HTTP responses.
  if isinstance(error,(ValueError,RuntimeError)):sys.exit(str(error))
  sys.exit('Landet publication failed; inspect protected state and connectivity, not credentials.')
