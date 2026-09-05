#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

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
Usage: step22b-cloudflare-homeassistant-validation.sh [--help]

Read-only local, Cloudflare API, and unauthenticated external validation for
the published Home Assistant hostname.
EOF
}

[[ "${1:-}" != "--help" ]] || { usage; exit 0; }
[[ $# -eq 0 ]] || die "Unknown argument: $1"
[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in awk curl dig pct python3 qm; do command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"; done
[[ -n "${TOKEN}" && -n "${HA_TOKEN}" ]] || die "Cloudflare and Home Assistant tokens are required"

"${PROJECT_ROOT}/scripts/step22a-cloudflare-access-validation.sh" --access-only >/dev/null

ha_ip="$(qm agent "${HA_VM_ID}" network-get-interfaces 2>/dev/null | awk '/"ip-address" :/ {ip=$3; gsub(/[",]/, "", ip)} /"ip-address-type" : "ipv4"/ {if (ip !~ /^(127|169\.254|172\.30)\./) {print ip; exit}}')"
proxy_ip="$(pct exec "${CT_ID}" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
origin="http://${ha_ip}:${HA_PORT}"

curl -fsS -H "Authorization: Bearer ${HA_TOKEN}" --max-time 10 "${origin}/api/config" >/dev/null \
  || die "Home Assistant API is unavailable"
http_storage="$(qm guest exec "${HA_VM_ID}" -- /usr/bin/docker exec -e "EXPECTED_PROXY=${proxy_ip}/32" homeassistant python3 -c '
import json, os
d=json.load(open("/config/.storage/http"))["data"]
s=d.get("stable") or {}
assert s.get("use_x_forwarded_for") is True
assert s.get("trusted_proxies") == [os.environ["EXPECTED_PROXY"]]
assert d.get("pending") is None
print("stable")
' 2>&1)"
printf '%s' "${http_storage}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d.get("exitcode")==0, (d.get("err-data") or d.get("out-data") or "guest command failed")
assert d.get("out-data", "").strip()=="stable"
' || die "Home Assistant HTTP setting is not stably promoted"
xff_status="$(pct exec "${CT_ID}" -- curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H 'X-Forwarded-For: 203.0.113.10' "${origin}/")"
[[ "${xff_status}" == "200" ]] || die "Home Assistant trusted-proxy test returned HTTP ${xff_status}"

api_get() { curl -fsS -H "Authorization: Bearer ${TOKEN}" "https://api.cloudflare.com/client/v4/$1"; }
if [[ -z "${TUNNEL_ID}" ]]; then
  TUNNEL_ID="$(api_get "accounts/${ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}" | TUNNEL_NAME="${TUNNEL_NAME}" python3 -c 'import json,os,sys; x=[i for i in json.load(sys.stdin).get("result",[]) if i.get("name")==os.environ["TUNNEL_NAME"] and not i.get("deleted_at")]; assert len(x)==1; print(x[0]["id"])')" \
    || die "Could not discover tunnel"
fi

config="$(api_get "accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations")"
HOSTNAME="${HOSTNAME}" ORIGIN="${origin}" python3 -c '
import json,os,sys
c=(json.load(sys.stdin).get("result") or {}).get("config") or {}; i=c.get("ingress") or []
assert sum(1 for x in i if x.get("hostname")==os.environ["HOSTNAME"] and x.get("service")==os.environ["ORIGIN"])==1
assert i and "hostname" not in i[-1]
' <<<"${config}" || die "Tunnel ingress validation failed"

dns="$(api_get "zones/${ZONE_ID}/dns_records?name=${HOSTNAME}")"
HOSTNAME="${HOSTNAME}" TARGET="${TUNNEL_ID}.cfargotunnel.com" python3 -c '
import json,os,sys
x=json.load(sys.stdin).get("result",[])
assert len(x)==1 and x[0].get("type")=="CNAME" and x[0].get("name")==os.environ["HOSTNAME"] and x[0].get("content")==os.environ["TARGET"] and x[0].get("proxied") is True
' <<<"${dns}" || die "DNS validation failed"

edge_ip="$(dig +short @1.1.1.1 "${HOSTNAME}" A | awk '/^[0-9.]+$/ {print; exit}')"
[[ -n "${edge_ip}" ]] || die "Cloudflare public DNS does not resolve ${HOSTNAME}"
headers="$(curl -sS -D - -o /dev/null --max-time 20 --resolve "${HOSTNAME}:443:${edge_ip}" "https://${HOSTNAME}/")"
status="$(awk 'toupper($1) ~ /^HTTP\// {code=$2} END {print code}' <<<"${headers}")"
location="$(awk 'BEGIN{IGNORECASE=1} /^location:/ {sub(/^[^:]*:[[:space:]]*/,""); gsub(/\r/,""); print; exit}' <<<"${headers}")"
[[ "${status}" =~ ^30[12378]$ && "${location}" == *"/cdn-cgi/access/login"* ]] \
  || die "Public URL does not redirect to Cloudflare Access"

log_info "Step 22B Cloudflare Home Assistant validation passed"
log_info "Local origin and trusted proxy: healthy"
log_info "Tunnel and DNS: correct; unauthenticated request: Access redirect"
