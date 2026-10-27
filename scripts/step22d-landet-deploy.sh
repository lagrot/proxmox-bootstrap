#!/usr/bin/env bash
# Isolated protected viewer. Does not create DNS or tunnel ingress.
set -Eeuo pipefail
umask 0077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
usage(){ echo 'Usage: step22d-landet-deploy.sh --dry-run | --apply | --validate | --rollback'; }
[[ $# == 1 ]] || { usage >&2; exit 2; }
case "$1" in --dry-run|--apply|--validate|--rollback) mode="$1";; --help) usage; exit 0;; *) usage >&2; exit 2;; esac
source "$ROOT/config/defaults.conf"
source "$ROOT/config/local.conf"
CT=240
MANAGED='Managed Landet viewer - proxmox-bootstrap'
state=/var/lib/proxmox-bootstrap/landet
if pct status "$CT" >/dev/null 2>&1; then
 pct config "$CT" | python3 -c 'import sys,urllib.parse; rows=dict(line.rstrip("\n").split(": ",1) for line in sys.stdin if ": " in line); sys.exit(not (urllib.parse.unquote(rows.get("description","")).strip()=="Managed Landet viewer - proxmox-bootstrap" and rows.get("hostname")=="landet-viewer" and rows.get("unprivileged")=="1"))' || { echo 'CT240 belongs to another workflow; refusing' >&2; exit 1; }
 exists=1
else exists=0; fi
if [[ "$mode" == --dry-run ]]; then
 echo 'Would create/reuse CT240 landet-viewer: unprivileged, 1 core, 512 MiB RAM, 256 MiB swap, 8 GiB rootfs.'
 echo 'Would install nginx, Debian PyJWT/cryptography and two unprivileged services.'
 echo 'Would require the dedicated Access audience/owner and allow origin traffic only from CT230.'
 echo 'Would retain prior release/root-only configuration for rollback. No DNS or tunnel changes.'
 [[ -f "$state/access.json" ]] || echo 'Apply prerequisite: verified owner-only Landet Access application.'
 exit 0
fi
[[ "$mode" != --apply || -f "$state/access.json" ]] || { echo 'Run step22d-landet-access.sh --apply first' >&2; exit 1; }
if [[ "$mode" != --validate ]]; then
 exec 9>/run/lock/proxmox-bootstrap-landet-deploy.lock
 flock -n 9 || { echo 'Another deployment is running' >&2; exit 1; }
fi
if [[ "$mode" == --rollback ]]; then
 [[ "$exists" == 1 ]] || { echo 'No managed container'; exit 1; }
 pct exec "$CT" -- bash -se <<'ROLLBACK'
set -Eeuo pipefail
if [[ -f /var/lib/landet-deploy/previous ]]; then
 prev="$(cat /var/lib/landet-deploy/previous)"
 [[ "$prev" =~ ^/opt/landet/releases/[a-f0-9]{16}$ && -d "$prev" ]] || exit 1
 cp -a /var/lib/landet-deploy/previous-env /etc/landet/viewer.env
 cp -a /var/lib/landet-deploy/previous-relay /etc/landet/relay.json
 cp -a /var/lib/landet-deploy/previous-nginx /etc/nginx/sites-available/landet
 cp -a /var/lib/landet-deploy/previous-landet.service /etc/systemd/system/landet.service
 cp -a /var/lib/landet-deploy/previous-landet-relay.service /etc/systemd/system/landet-relay.service
 systemctl daemon-reload
 nginx -t
 ln -sfn "$prev" /opt/landet/current
 systemctl restart landet-relay landet nginx
else
 systemctl disable --now landet landet-relay nginx
fi
ROLLBACK
 echo 'Restored previous release or stopped initial unpublished services; container and data retained.'
 exit 0
fi
if [[ "$mode" == --validate ]]; then
 [[ "$exists" == 1 ]] || exit 1
 pct exec "$CT" -- bash -se <<'VALIDATE'
set -Eeuo pipefail
systemctl is-active --quiet landet landet-relay nginx
nginx -t
python3 - <<'PY'
import urllib.request,urllib.error,json
with urllib.request.urlopen('http://127.0.0.1:8765/healthz',timeout=5) as r:
 assert json.load(r)['mode']=='access'
for path in ['/','/api/climate','/api/clips','/api/cameras/c200/live.mp4']:
 for token in ['', 'forged.jwt.signature']:
  try:
   urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8765'+path,headers={'Cf-Access-Jwt-Assertion':token}),timeout=5)
   raise AssertionError('Unauthenticated data reached')
  except urllib.error.HTTPError as e: assert e.code==401
print('Access mode, services and rejection of missing/forged tokens pass.')
import os,subprocess,sys
values=dict(line.rstrip('\n').split('=',1) for line in open('/etc/landet/viewer.env') if '=' in line)
env=os.environ.copy();env.update({k:json.loads(v) for k,v in values.items()})
subprocess.run([sys.executable,'/opt/landet/current/proof/server.py','--check'],env=env,check=True)
PY
VALIDATE
 exit 0
fi
work="$(mktemp -d /tmp/landet-deploy.XXXXXXXX)"
activated=0
cleanup() {
 rc=$?
 trap - EXIT
 if ((rc != 0 && activated == 1)); then
  echo 'Deployment validation failed; restoring prior release or stopping initial services' >&2
  flock -u 9
  bash "$0" --rollback || echo 'Automatic rollback failed; inspect CT240 before publishing' >&2
 fi
 rm -rf -- "$work"
 exit "$rc"
}
trap cleanup EXIT
if [[ "$exists" == 0 ]]; then
 # pct's unprivileged extractor must traverse its non-secret work directory.
 # A previous failed create may leave only empty directories; never remove data.
 if [[ -d "/var/lib/lxc/$CT" ]]; then
  rmdir "/var/lib/lxc/$CT/rootfs" "/var/lib/lxc/$CT" || { echo 'Unexpected CT240 creation remnants; refusing cleanup' >&2; exit 1; }
 fi
 (umask 0022; pct create "$CT" local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname landet-viewer --description "$MANAGED" --unprivileged 1 \
  --cores 1 --memory 512 --swap 256 --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,type=veth --onboot 1)
fi
[[ "$(pct status "$CT")" == 'status: running' ]] || pct start "$CT"
for ((i=0;i<30;i++)); do
 if pct exec "$CT" -- ip -j -4 addr show dev eth0 | python3 -c 'import sys,json; sys.exit(not any(x.get("scope")=="global" for a in json.load(sys.stdin) for x in a.get("addr_info",[])))'; then break; fi
 sleep 1
done
((i<30)) || { echo 'DHCP did not become ready' >&2; exit 1; }
pct exec "$CT" -- bash -se <<'PACKAGES'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
missing=0
for package in ca-certificates python3 python3-jwt python3-cryptography nginx; do
 dpkg -s "$package" 2>/dev/null | grep -qx 'Status: install ok installed' || missing=1
done
if ((missing)); then
 apt-get update --error-on=any
 apt-get install -y --no-install-recommends ca-certificates python3 python3-jwt python3-cryptography nginx
fi
for service in ssh.service ssh.socket postfix.service; do
 if systemctl cat "$service" >/dev/null 2>&1; then systemctl disable --now "$service"; fi
done
id landet >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin landet
install -d -m 0755 /opt/landet/releases /etc/landet
install -d -m 0700 /var/lib/landet-deploy
printf 'APT::Periodic::Unattended-Upgrade "0";\n' > /etc/apt/apt.conf.d/99-landet-manual-updates
PACKAGES
pct exec "${DOCKER_CT_ID:-200}" -- docker exec frigate cat /usr/local/go2rtc/bin/go2rtc > "$work/go2rtc"
# Private configuration is written only into the protected temporary directory.
export HA_TOKEN
python3 - "$ROOT" "$work" "$state/access.json" "${HA_VM_ID:-100}" "${DOCKER_CT_ID:-200}" <<'CONFIG'
import hashlib,ipaddress,json,os,pathlib,subprocess,sys,tarfile
root,work=map(pathlib.Path,sys.argv[1:3]);access=json.load(open(sys.argv[3]))
def run(*args):return json.loads(subprocess.check_output(args,stderr=subprocess.DEVNULL))
def ct_ip(ct):
 rows=run('pct','exec',ct,'--','ip','-j','-4','addr','show','dev','eth0')
 ips=[x['local'] for a in rows for x in a.get('addr_info',[]) if x.get('scope')=='global']
 if len(ips)!=1:raise ValueError('Ambiguous CT network')
 return ips[0]
ha=run('qm','agent',sys.argv[4],'network-get-interfaces')
ips=[x['ip-address'] for a in ha for x in a.get('ip-addresses',[]) if x.get('ip-address-type')=='ipv4' and ipaddress.ip_address(x['ip-address']).is_private and not x['ip-address'].startswith(('127.','172.30.','169.254.'))]
if len(ips)!=1:raise ValueError('Ambiguous HA network')
code='import yaml,json; c=yaml.safe_load(open("/config/config.yml")); print(json.dumps({k:next(x["path"] for x in c["cameras"][n]["ffmpeg"]["inputs"] if "record" in x.get("roles",[])) for k,n in {"c200":"tplink_c200_1","c320":"tplink_c320ws_1"}.items()}))'
streams=run('pct','exec',sys.argv[5],'--','docker','exec','frigate','python3','-c',code)
relay={'api':{'listen':'127.0.0.1:1986'},'rtsp':{'listen':''},'webrtc':{'listen':''},'streams':streams,'log':{'level':'error'}}
(work/'relay.json').write_text(json.dumps(relay))
env={'LANDET_MODE':'access','LANDET_ACCESS_ISSUER':access['issuer'],'LANDET_ACCESS_AUD':access['audience'],'LANDET_OWNER_EMAIL':access['owner_email'],
 'HA_TOKEN':os.environ['HA_TOKEN'],'LANDET_HA_ORIGIN':'http://'+ips[0]+':8123','LANDET_FRIGATE_ORIGIN':'http://'+ct_ip(sys.argv[5])+':5000','LANDET_RELAY_ORIGIN':'http://127.0.0.1:1986'}
(work/'viewer.env').write_text(''.join(k+'='+json.dumps(v)+'\n' for k,v in env.items()))
gateway=ct_ip('230')
nginx='''server {
 listen 8080 default_server;
 server_name _;
 access_log off;
 client_max_body_size 1k;
 allow 127.0.0.1;
 allow GATEWAY;
 deny all;
 location / {
  proxy_pass http://127.0.0.1:8765;
  proxy_set_header Host 127.0.0.1:8765;
  proxy_set_header Cf-Access-Jwt-Assertion $http_cf_access_jwt_assertion;
  proxy_http_version 1.1;
  proxy_buffering off;
  proxy_read_timeout 75s;
 }
}'''.replace('GATEWAY',gateway)
(work/'nginx.conf').write_text(nginx)
def normalized(info):
 info.uid=info.gid=0;info.uname=info.gname='root';info.mtime=0
 return info
with tarfile.open(work/'release.tar','w') as tar:
 for path in sorted((root/'viewer/proof').rglob('*')):
  if path.is_file() and '__pycache__' not in path.parts:tar.add(path,arcname='proof/'+str(path.relative_to(root/'viewer/proof')),filter=normalized)
 tar.add(work/'go2rtc',arcname='go2rtc',filter=normalized)
release=hashlib.sha256((work/'release.tar').read_bytes()).hexdigest()[:16]
(work/'release-id').write_text(release)
CONFIG
for name in release.tar relay.json viewer.env nginx.conf release-id; do
 pct push "$CT" "$work/$name" "/var/lib/landet-deploy/$name" --perms 0600
done
for name in landet.service landet-relay.service; do pct push "$CT" "$ROOT/viewer/deploy/$name" "/var/lib/landet-deploy/$name" --perms 0644; done
activated=1
pct exec "$CT" -- bash -se <<'INSTALL'
set -Eeuo pipefail
state=/var/lib/landet-deploy
release="$(cat "$state/release-id")"
[[ "$release" =~ ^[a-f0-9]{16}$ ]] || exit 1
target="/opt/landet/releases/$release"
if [[ -L /opt/landet/current && "$(readlink -f /opt/landet/current)" == "$target" ]] &&
 cmp -s "$state/viewer.env" /etc/landet/viewer.env && cmp -s "$state/relay.json" /etc/landet/relay.json &&
 cmp -s "$state/nginx.conf" /etc/nginx/sites-available/landet &&
 cmp -s "$state/landet.service" /etc/systemd/system/landet.service &&
 cmp -s "$state/landet-relay.service" /etc/systemd/system/landet-relay.service &&
 systemctl is-active --quiet landet landet-relay nginx; then
 rm -f "$state/release.tar" "$state/relay.json" "$state/viewer.env"
 echo 'Release/configuration already current; no service restart.'
 exit 0
fi
if [[ -L /opt/landet/current ]] && systemctl is-active --quiet landet landet-relay nginx; then
 readlink -f /opt/landet/current > "$state/previous"
 cp -a /etc/landet/viewer.env "$state/previous-env"
 cp -a /etc/landet/relay.json "$state/previous-relay"
 cp -a /etc/nginx/sites-available/landet "$state/previous-nginx"
 cp -a /etc/systemd/system/landet.service "$state/previous-landet.service"
 cp -a /etc/systemd/system/landet-relay.service "$state/previous-landet-relay.service"
fi
install -d -m 0755 "$target"
tar -xf "$state/release.tar" -C "$target"
find "$target" -type d -exec chmod 0755 {} +
find "$target" -type f -exec chmod 0644 {} +
chmod 0755 "$target/go2rtc"
cp "$state/landet.service" /etc/systemd/system/landet.service
cp "$state/landet-relay.service" /etc/systemd/system/landet-relay.service
cp "$state/viewer.env" /etc/landet/viewer.env
install -m 0640 -o root -g landet "$state/relay.json" /etc/landet/relay.json
rm -f /etc/nginx/sites-enabled/default
cp "$state/nginx.conf" /etc/nginx/sites-available/landet
ln -sfn /etc/nginx/sites-available/landet /etc/nginx/sites-enabled/landet
nginx -t
ln -sfn "$target" /opt/landet/current
systemctl daemon-reload
systemctl enable landet-relay landet nginx
systemctl restart landet-relay landet nginx
rm -f "$state/release.tar" "$state/relay.json" "$state/viewer.env"
INSTALL
bash "$0" --validate
echo 'Viewer services deployed and fail-closed checks passed. DNS/tunnel configuration was not changed.'
