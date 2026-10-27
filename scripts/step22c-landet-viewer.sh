#!/usr/bin/env bash
# Temporary loopback proof only: no guest/config/service changes.
set -Eeuo pipefail
umask 0077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo 'Usage: step22c-landet-viewer.sh --dry-run | --check | --serve | --serve-hq | --help'; }
[[ $# == 1 ]] || { usage >&2; exit 2; }
case "$1" in --help) usage; exit 0;; --dry-run|--check|--serve|--serve-hq) mode="$1";; *) usage >&2; exit 2;; esac
for command in python3 pct qm; do command -v "$command" >/dev/null || { echo "Missing $command" >&2; exit 1; }; done
source "$ROOT/config/defaults.conf"
[[ ! -f "$ROOT/config/local.conf" ]] || source "$ROOT/config/local.conf"
[[ -n "${HA_TOKEN:-}" ]] || { echo 'HA_TOKEN missing from protected config/local.conf' >&2; exit 1; }
ha_json="$(qm agent "${HA_VM_ID:-100}" network-get-interfaces)"
ha_ip="$(printf '%s' "$ha_json" | python3 -c 'import json,sys,ipaddress; a=[x["ip-address"] for n in json.load(sys.stdin) for x in n.get("ip-addresses",[]) if x.get("ip-address-type")=="ipv4" and ipaddress.ip_address(x["ip-address"]).is_private and not x["ip-address"].startswith(("127.","172.30.","169.254."))]; sys.exit("Expected one HA LAN address") if len(a)!=1 else print(a[0])')"
ct_json="$(pct exec "${DOCKER_CT_ID:-200}" -- ip -j -4 addr show dev eth0)"
ct_ip="$(printf '%s' "$ct_json" | python3 -c 'import json,sys; a=[x["local"] for n in json.load(sys.stdin) for x in n.get("addr_info",[]) if x.get("scope")=="global"]; sys.exit("Expected one Docker CT address") if len(a)!=1 else print(a[0])')"
export HA_TOKEN
export LANDET_HA_ORIGIN="http://${ha_ip}:${HA_HTTP_PORT:-8123}"
export LANDET_FRIGATE_ORIGIN="http://${ct_ip}:${FRIGATE_INTERNAL_PORT:-5000}"
port="${LANDET_PROOF_PORT:-8765}"
[[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535)) || { echo 'Invalid proof port' >&2; exit 2; }
case "$mode" in
 --dry-run) echo "Would run two-camera/twelve-clip/four-thermometer read-only proof on 127.0.0.1:${port}."; echo 'No installs, guest changes, service restarts, or public routes. Upstreams discovered.';;
 --check) exec python3 "$ROOT/viewer/proof/server.py" --check;;
 --serve) exec python3 "$ROOT/viewer/proof/server.py" --port "$port";;
 --serve-hq)
  # A private temporary process; no Frigate configuration or persistent service.
  command -v flock >/dev/null || { echo 'Missing flock' >&2; exit 1; }
  exec 9>/run/lock/proxmox-bootstrap-landet-viewer.lock
  flock -n 9 || { echo 'An HQ proof is already running' >&2; exit 1; }
  relay_port="${LANDET_RELAY_PORT:-1986}"
  [[ "$relay_port" == 1986 || "$relay_port" == 1987 ]] || { echo "Invalid relay port" >&2; exit 2; }
  python3 - "$port" "$relay_port" <<'PYPORT'
import socket,sys
for port in [int(sys.argv[2]),int(sys.argv[1])]:
    with socket.socket() as s:
        s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        try: s.bind(('127.0.0.1',port))
        except OSError: sys.exit('Pilot port is occupied; no relay started')
PYPORT
  work="$(mktemp -d /tmp/landet-hq.XXXXXXXX)"
  relay_pid=''
  cleanup() {
    [[ -z "$relay_pid" ]] || { kill "$relay_pid" 2>/dev/null || true; wait "$relay_pid" 2>/dev/null || true; }
    rm -rf -- "$work"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  pct exec "${DOCKER_CT_ID:-200}" -- docker exec frigate cat /usr/local/go2rtc/bin/go2rtc > "$work/go2rtc"
  chmod 700 "$work/go2rtc"
  python3 - "$work/relay.json" "${DOCKER_CT_ID:-200}" "$relay_port" <<'PYHQ'
import json,subprocess,sys
try:
    code='import yaml,json; c=yaml.safe_load(open("/config/config.yml")); print(json.dumps({k:next(x["path"] for x in c["cameras"][n]["ffmpeg"]["inputs"] if "record" in x.get("roles",[])) for k,n in {"c200":"tplink_c200_1","c320":"tplink_c320ws_1"}.items()}))'
    source=json.loads(subprocess.check_output(['pct','exec',sys.argv[2],'--','docker','exec','frigate','python3','-c',code],stderr=subprocess.DEVNULL))
    if not all(x.startswith('rtsp://') for x in source.values()): raise ValueError()
    config={'api':{'listen':'127.0.0.1:'+sys.argv[3]},'rtsp':{'listen':''},'webrtc':{'listen':''},'streams':source,'log':{'level':'error'}}
    with open(sys.argv[1],'w') as f: json.dump(config,f)
except Exception:
    sys.exit('Cannot prepare private pilot stream; no configuration changed')
PYHQ
  "$work/go2rtc" -config "$work/relay.json" > /dev/null 2>&1 &
  relay_pid=$!
  sleep 1
  kill -0 "$relay_pid" 2>/dev/null || { echo 'Temporary relay failed; check occupied port 1986' >&2; exit 1; }
  export LANDET_RELAY_ORIGIN="http://127.0.0.1:${relay_port}"
  python3 "$ROOT/viewer/proof/server.py" --port "$port"
  ;;

esac
