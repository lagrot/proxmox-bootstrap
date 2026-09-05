#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

MODE=""
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
ZONE_ID="${CLOUDFLARE_ZONE_ID:-cdc57b6899bf5275cad362cd8425b054}"
TOKEN="${CLOUDFLARE_API_TOKEN:-}"
TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-}"
TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-nad9-remote-gateway}"
CT_ID="${CLOUDFLARE_GATEWAY_CT_ID:-230}"
HA_VM_ID="${HA_VM_ID:-100}"
HA_PORT="${HA_HTTP_PORT:-8123}"
HA_TOKEN="${HA_TOKEN:-}"
HOSTNAME="${CLOUDFLARE_HA_HOSTNAME:-ha.ostmarken.se}"

usage() {
  cat <<'EOF'
Usage: step22b-cloudflare-homeassistant-publish.sh --dry-run | --apply

Safely configure Home Assistant to trust the Cloudflare gateway, publish its
tunnel ingress and proxied CNAME, and verify Cloudflare Access intercepts an
unauthenticated internet request.
EOF
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
case "$1" in
  --dry-run|--apply) MODE="$1" ;;
  --help) usage; exit 0 ;;
  *) die "Unknown argument: $1" ;;
esac

[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in awk base64 curl dig pct python3 qm; do command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"; done
[[ "${ACCOUNT_ID}" =~ ^[0-9a-fA-F]{32}$ ]] || die "CLOUDFLARE_ACCOUNT_ID is invalid"
[[ "${ZONE_ID}" =~ ^[0-9a-fA-F]{32}$ ]] || die "CLOUDFLARE_ZONE_ID is invalid"
[[ -n "${TOKEN}" ]] || die "CLOUDFLARE_API_TOKEN is not set"
[[ -n "${HA_TOKEN}" ]] || die "HA_TOKEN is not set"
[[ "${HOSTNAME}" =~ ^[A-Za-z0-9.-]+$ ]] || die "CLOUDFLARE_HA_HOSTNAME is invalid"
[[ "$(qm status "${HA_VM_ID}" 2>/dev/null)" == "status: running" ]] || die "Home Assistant VM ${HA_VM_ID} is not running"
[[ "$(pct status "${CT_ID}" 2>/dev/null)" == "status: running" ]] || die "Cloudflare gateway CT ${CT_ID} is not running"

tmp_dir="$(mktemp -d)"
publish_started=0
tunnel_changed=0
dns_created_id=""
previous_tunnel_body=""

cleanup() {
  local rc=$?
  trap - EXIT
  if [[ "${rc}" -ne 0 && "${publish_started}" -eq 1 ]]; then
    log_warn "Publish failed; rolling back Cloudflare route changes"
    if [[ -n "${dns_created_id}" ]]; then
      curl -fsS -X DELETE -H "Authorization: Bearer ${TOKEN}" \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${dns_created_id}" >/dev/null 2>&1 || true
    fi
    if [[ "${tunnel_changed}" -eq 1 && -n "${previous_tunnel_body}" ]]; then
      curl -fsS -X PUT -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
        --data "${previous_tunnel_body}" \
        "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf -- "${tmp_dir}"
  exit "${rc}"
}
trap cleanup EXIT

api_request() {
  local method="$1" url="$2" body="${3:-}" output="${tmp_dir}/response.json" status
  if [[ -n "${body}" ]]; then
    status="$(curl -sS -o "${output}" -w '%{http_code}' -X "${method}" \
      -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
      --data "${body}" "${url}")" || die "Cloudflare API request failed"
  else
    status="$(curl -sS -o "${output}" -w '%{http_code}' -X "${method}" \
      -H "Authorization: Bearer ${TOKEN}" "${url}")" || die "Cloudflare API request failed"
  fi
  if [[ ! "${status}" =~ ^2 ]]; then
    python3 - "${output}" "${status}" <<'PY' >&2
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    errors = "; ".join(str(x.get("message", x)) for x in data.get("errors", []))
except Exception:
    errors = ""
print(f"Cloudflare API returned HTTP {sys.argv[2]}" + (": " + errors if errors else ""))
PY
    return 1
  fi
  python3 - "${output}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if not data.get("success"):
    raise SystemExit("Cloudflare API reported failure: " + "; ".join(str(x.get("message", x)) for x in data.get("errors", [])))
PY
  cat "${output}"
}

discover_ha_ip() {
  qm agent "${HA_VM_ID}" network-get-interfaces 2>/dev/null \
    | awk '/"ip-address" :/ {ip=$3; gsub(/[",]/, "", ip)} /"ip-address-type" : "ipv4"/ {if (ip !~ /^(127|169\.254|172\.30)\./) {print ip; exit}}'
}

discover_ct_ip() {
  pct exec "${CT_ID}" -- ip -4 -o addr show dev eth0 2>/dev/null \
    | awk '{split($4,a,"/"); print a[1]; exit}'
}

ha_websocket() {
  local action="$1" proxy_ip="${2:-}" code_b64 result
  code_b64="$(base64 -w0 <<'PY'
import json
import os
import ipaddress
import websocket

token = os.environ["HASS_TOKEN"]
action = os.environ["HA_WS_ACTION"]
proxy_ip = os.environ.get("HA_PROXY_IP", "")
proxy_network = str(ipaddress.ip_network(proxy_ip)) if proxy_ip else ""

def request(ws, message_id, message_type, **payload):
    ws.send(json.dumps({"id": message_id, "type": message_type, **payload}))
    while True:
        response = json.loads(ws.recv())
        if response.get("id") == message_id:
            if not response.get("success"):
                error = response.get("error", {})
                raise RuntimeError(error.get("message", "Home Assistant request failed"))
            return response.get("result")

ws = websocket.create_connection("ws://127.0.0.1:8123/api/websocket", timeout=30)
try:
    if json.loads(ws.recv()).get("type") != "auth_required":
        raise RuntimeError("Home Assistant WebSocket did not request authentication")
    ws.send(json.dumps({"type": "auth", "access_token": token}))
    if json.loads(ws.recv()).get("type") != "auth_ok":
        raise RuntimeError("Home Assistant WebSocket authentication failed")
    current = request(ws, 1, "http/config")
    if action == "inspect":
        print(json.dumps(current, sort_keys=True))
    elif action == "configure":
        stable = current.get("stable") or current.get("default") or {}
        desired = {k: v for k, v in stable.items() if k not in {"created_at", "error", "error_message"}}
        desired["use_x_forwarded_for"] = True
        desired["trusted_proxies"] = [proxy_network]
        print(json.dumps(request(ws, 2, "http/config/configure", config=desired), sort_keys=True))
    elif action == "promote":
        pending = current.get("pending")
        if pending is None:
            stable = current.get("stable") or {}
            if stable.get("use_x_forwarded_for") is True and stable.get("trusted_proxies") == [proxy_network]:
                print("already_promoted")
            else:
                raise RuntimeError("No matching pending HTTP configuration to promote")
        else:
            if pending.get("use_x_forwarded_for") is not True or pending.get("trusted_proxies") != [proxy_network]:
                raise RuntimeError("Pending HTTP configuration differs from the requested proxy")
            request(ws, 2, "http/config/promote")
            print("promoted")
    else:
        raise RuntimeError("Unknown action")
finally:
    ws.close()
PY
)"
  result="$(qm guest exec "${HA_VM_ID}" -- /usr/bin/docker exec \
    -e "HASS_TOKEN=${HA_TOKEN}" -e "HA_WS_ACTION=${action}" -e "HA_PROXY_IP=${proxy_ip}" \
    -e "PYTHON_CODE_B64=${code_b64}" homeassistant python3 -c \
    'import base64,os; exec(compile(base64.b64decode(os.environ["PYTHON_CODE_B64"]), "step22b-ha-http.py", "exec"))' 2>&1)" \
    || { log_error "Home Assistant HTTP configuration request failed"; return 1; }
  printf '%s' "${result}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
if d.get("exitcode") != 0:
    message=(d.get("err-data") or d.get("out-data") or "guest command failed").strip()
    raise SystemExit(message)
print(d.get("out-data", "").strip())
'
}

wait_for_ha() {
  local ha_ip="$1" attempt
  for attempt in $(seq 1 60); do
    if curl -fsS -H "Authorization: Bearer ${HA_TOKEN}" --max-time 5 \
      "http://${ha_ip}:${HA_PORT}/api/config" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

log_info "Step 22B Home Assistant publish: ${MODE}"
"${PROJECT_ROOT}/scripts/step22a-cloudflare-access-validation.sh" --access-only >/dev/null

ha_ip="$(discover_ha_ip)"
proxy_ip="$(discover_ct_ip)"
[[ "${ha_ip}" =~ ^[0-9.]+$ ]] || die "Could not discover the Home Assistant IP"
[[ "${proxy_ip}" =~ ^[0-9.]+$ ]] || die "Could not discover CT ${CT_ID} IP"
origin="http://${ha_ip}:${HA_PORT}"
log_info "Home Assistant ${origin}; trusted proxy ${proxy_ip}"

pct exec "${CT_ID}" -- curl -fsS --max-time 10 "${origin}/" >/dev/null \
  || die "CT ${CT_ID} cannot reach Home Assistant"

if [[ -z "${TUNNEL_ID}" ]]; then
  tunnels="$(api_request GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}")"
  TUNNEL_ID="$(TUNNEL_NAME="${TUNNEL_NAME}" python3 -c '
import json, os, sys
items = [x for x in json.load(sys.stdin).get("result", []) if x.get("name") == os.environ["TUNNEL_NAME"] and not x.get("deleted_at")]
if len(items) != 1: raise SystemExit("Expected exactly one tunnel")
print(items[0]["id"])
' <<<"${tunnels}")" || die "Could not discover tunnel ${TUNNEL_NAME}"
fi

tunnel_response="$(api_request GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations")"
dns_response="$(api_request GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${HOSTNAME}")"
dns_state="$(HOSTNAME="${HOSTNAME}" TARGET="${TUNNEL_ID}.cfargotunnel.com" python3 -c '
import json, os, sys
items = json.load(sys.stdin).get("result", [])
if not items: print("absent")
elif len(items) == 1 and items[0].get("type") == "CNAME" and items[0].get("content") == os.environ["TARGET"] and items[0].get("proxied") is True: print("correct")
else: print("conflict")
' <<<"${dns_response}")"
[[ "${dns_state}" != "conflict" ]] || die "A conflicting DNS record already exists for ${HOSTNAME}"

current_http="$(ha_websocket inspect "${proxy_ip}")"
http_state="$(PROXY_IP="${proxy_ip}" python3 -c '
import ipaddress, json, os, sys
d=json.load(sys.stdin); stable=d.get("stable") or {}; pending=d.get("pending") or {}
expected=[str(ipaddress.ip_network(os.environ["PROXY_IP"]))]
def matches(x): return x.get("use_x_forwarded_for") is True and x.get("trusted_proxies") == expected
print("correct" if matches(stable) else "pending" if matches(pending) else "change")
' <<<"${current_http}")"

if [[ "${MODE}" == "--dry-run" ]]; then
  case "${http_state}" in
    correct) log_info "Would reuse current HA trusted-proxy setting" ;;
    pending) log_info "Would verify and promote the matching staged HA trusted-proxy setting" ;;
    change) log_info "Would back up, stage, restart, verify, and promote HA trusted-proxy setting" ;;
  esac
  log_info "Would reconcile tunnel ingress ${HOSTNAME} -> ${origin}"
  [[ "${dns_state}" == "correct" ]] && log_info "Would reuse the existing proxied CNAME" || log_info "Would create the proxied CNAME"
  log_info "Would verify the public URL stops at Cloudflare Access"
  exit 0
fi

if [[ "${http_state}" == "change" ]]; then
  backup_name="http.step22b.$(date -u +%Y%m%dT%H%M%SZ).bak"
  qm guest exec "${HA_VM_ID}" -- /usr/bin/docker exec homeassistant sh -c \
    "umask 077; cp /config/.storage/http /config/.storage/${backup_name}" >/dev/null \
    || die "Could not back up Home Assistant HTTP settings"
  log_info "Backed up Home Assistant HTTP settings as .storage/${backup_name}"
  ha_websocket configure "${proxy_ip}" >/dev/null
  log_info "Home Assistant restart requested with staged HTTP settings"
  wait_for_ha "${ha_ip}" || die "Home Assistant did not return; its staged setting will auto-revert"
elif [[ "${http_state}" == "pending" ]]; then
  log_info "Reusing the matching staged Home Assistant HTTP setting"
fi

xff_status="$(pct exec "${CT_ID}" -- curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
  -H 'X-Forwarded-For: 203.0.113.10' "${origin}/")"
[[ "${xff_status}" == "200" ]] || die "Home Assistant rejected the trusted-proxy test with HTTP ${xff_status}"
ha_websocket promote "${proxy_ip}" >/dev/null
log_info "Home Assistant trusted-proxy setting verified and promoted"

new_tunnel_body="$(HOSTNAME="${HOSTNAME}" ORIGIN="${origin}" python3 -c '
import json, os, sys
response=json.load(sys.stdin); config=(response.get("result") or {}).get("config") or {}
ingress=config.get("ingress") or []
kept=[x for x in ingress if x.get("hostname") != os.environ["HOSTNAME"] and "hostname" in x]
catch=next((x for x in ingress if "hostname" not in x), {"service":"http_status:404"})
config["ingress"] = kept + [{"hostname":os.environ["HOSTNAME"],"service":os.environ["ORIGIN"],"originRequest":{}}] + [catch]
print(json.dumps({"config":config}, separators=(",",":"), sort_keys=True))
' <<<"${tunnel_response}")"
previous_tunnel_body="$(python3 -c '
import json,sys
c=(json.load(sys.stdin).get("result") or {}).get("config") or {}
if not c.get("ingress"):
    c["ingress"]=[{"service":"http_status:404"}]
print(json.dumps({"config":c}, separators=(",",":"), sort_keys=True))
' <<<"${tunnel_response}")"

publish_started=1
if [[ "${new_tunnel_body}" != "${previous_tunnel_body}" ]]; then
  api_request PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" "${new_tunnel_body}" >/dev/null
  tunnel_changed=1
  log_info "Tunnel ingress configured"
else
  log_info "Reusing existing tunnel ingress"
fi

if [[ "${dns_state}" == "absent" ]]; then
  dns_body="$(HOSTNAME="${HOSTNAME}" TARGET="${TUNNEL_ID}.cfargotunnel.com" python3 -c 'import json,os; print(json.dumps({"type":"CNAME","name":os.environ["HOSTNAME"],"content":os.environ["TARGET"],"proxied":True,"ttl":1}))')"
  dns_created="$(api_request POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" "${dns_body}")"
  dns_created_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])' <<<"${dns_created}")"
  log_info "Created proxied CNAME for ${HOSTNAME}"
else
  log_info "Reusing existing proxied CNAME for ${HOSTNAME}"
fi

access_ok=0
status=""
location=""
for attempt in $(seq 1 30); do
  edge_ip="$(dig +short @1.1.1.1 "${HOSTNAME}" A 2>/dev/null | awk '/^[0-9.]+$/ {print; exit}')"
  if [[ -z "${edge_ip}" ]]; then
    sleep 2
    continue
  fi
  headers="$(curl -sS -D - -o /dev/null --max-time 15 --resolve "${HOSTNAME}:443:${edge_ip}" "https://${HOSTNAME}/" 2>/dev/null || true)"
  status="$(awk 'toupper($1) ~ /^HTTP\// {code=$2} END {print code}' <<<"${headers}")"
  location="$(awk 'BEGIN{IGNORECASE=1} /^location:/ {sub(/^[^:]*:[[:space:]]*/,""); gsub(/\r/,""); print; exit}' <<<"${headers}")"
  if [[ "${status}" =~ ^30[12378]$ && "${location}" == *"/cdn-cgi/access/login"* ]]; then
    access_ok=1
    break
  fi
  sleep 2
done
[[ "${access_ok}" -eq 1 ]] || die "Public URL did not present the Cloudflare Access login redirect (last HTTP status: ${status:-none})"

publish_started=0
log_info "Step 22B publish validation passed"
log_info "https://${HOSTNAME} is published behind Cloudflare Access"
log_info "Final authenticated browser test is still required"
