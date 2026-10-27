#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
usage() {
  echo 'Usage: step22c-landet-dashboard.sh --dry-run | --apply | --validate | --rollback'
  echo 'Create a two-camera viewing prototype on the existing Home Assistant URL.'
  echo 'No Cloudflare changes, new users, or changes to existing dashboards.'
}
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
case "$1" in
  --help) usage; exit 0 ;;
  --dry-run|--apply|--validate|--rollback) MODE="$1" ;;
  *) usage >&2; exit 2 ;;
esac
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"
[[ ${EUID} -eq 0 ]] || die 'Run as root on nad9-1'
for cmd in qm base64 python3 flock curl awk; do command -v "$cmd" >/dev/null || die "Missing command: ${cmd}"; done
[[ -n "${HA_TOKEN:-}" ]] || die 'HA_TOKEN is missing from config/local.conf'
[[ "$(qm status "${HA_VM_ID}")" == 'status: running' ]] || die 'Home Assistant VM is not running'
if [[ "${MODE}" == --apply || "${MODE}" == --rollback ]]; then
  exec 9>/run/lock/proxmox-bootstrap-landet-dashboard.lock
  flock -n 9 || die 'Another Landet dashboard operation is running'
fi
payload="$(base64 -w0 "${PROJECT_ROOT}/lib/landet_dashboard.py")"
ui_payload="$(base64 -w0 "${PROJECT_ROOT}/frontend/landet-cards.js")"
result="$(qm guest exec "${HA_VM_ID}" -- /usr/bin/docker exec \
  -e "HASS_TOKEN=${HA_TOKEN}" -e "DASHBOARD_MODE=${MODE}" \
  -e "C200_ENTITY=camera.${TAPO_C200_NAME:-${TAPO_CAMERA_NAME:-tplink_c200_1}}" \
  -e "C320WS_ENTITY=camera.${TAPO_C320WS_NAME:-tplink_c320ws_1}" \
  -e "LANDET_UI_B64=${ui_payload}" -e "PYTHON_CODE_B64=${payload}" homeassistant python3 -u -c \
  'import base64,os; exec(compile(base64.b64decode(os.environ["PYTHON_CODE_B64"]), "landet-dashboard.py", "exec"))')"
GUEST_RESULT="${result}" python3 - <<'PY'
import json, os, sys
r = json.loads(os.environ['GUEST_RESULT'])
print(r.get('out-data', ''), end='')
if r.get('exitcode') != 0 or not r.get('exited') or r.get('out-truncated'):
    print(r.get('err-data', '')[:1200], end='', file=sys.stderr)
    print('Landet dashboard operation failed; inspect the protected local state', file=sys.stderr)
    sys.exit(1)
PY
if [[ "${MODE}" == --apply || "${MODE}" == --validate ]]; then
  ha_ip="$(qm agent "${HA_VM_ID}" network-get-interfaces | awk '/"ip-address" :/ {ip=$3; gsub(/[",]/, "", ip)} /"ip-address-type" : "ipv4"/ {if (ip !~ /^(127|169\.254|172\.30)\./) {print ip; exit}}')"
  [[ -n "${ha_ip}" ]] || die 'Could not discover HA address'
  asset_url="http://${ha_ip}:${HA_HTTP_PORT:-8123}/local/proxmox-bootstrap/kiosk-mode-v15.0.0.js"
  asset_ready() {
    curl -fsS --max-time 5 "${asset_url}" 2>/dev/null | python3 -c 'import hashlib,sys; sys.exit(hashlib.sha256(sys.stdin.buffer.read()).hexdigest() != "b54c24054c27980faeace330bbf019f3b03e54acfda190573a26026cddbf6cf1")'
  }
  if ! asset_ready; then
    [[ "${MODE}" == --apply && "${result}" == *frontend_restart_needed=yes* ]] \
      || die 'Frontend module is not served correctly; dashboard UI is not verified'
    log_info 'Enabling the new local frontend route with one Home Assistant restart'
    check="$(qm guest exec "${HA_VM_ID}" -- /usr/bin/docker exec homeassistant python3 -m homeassistant --script check_config --config /config)"
    GUEST_CHECK="${check}" python3 -c 'import json,os,sys; r=json.loads(os.environ["GUEST_CHECK"]); sys.exit(0 if r.get("exited") and r.get("exitcode")==0 else 1)' \
      || die 'HA config validation failed; use --rollback before retrying'
    restart="$(qm guest exec "${HA_VM_ID}" -- /usr/bin/docker restart homeassistant)"
    GUEST_RESTART="${restart}" python3 -c 'import json,os,sys; r=json.loads(os.environ["GUEST_RESTART"]); sys.exit(0 if r.get("exited") and r.get("exitcode")==0 else 1)' \
      || die 'HA Core restart failed; prototype state retained for inspection'
    for ((attempt=0; attempt<60; attempt++)); do
      if asset_ready; then break; fi
      sleep 2
    done
    (( attempt < 60 )) || die 'Frontend module did not become available; inspect HA over Tailscale'
  fi
  log_info 'Pinned kiosk module is served correctly; owner browser preview is the next acceptance step'
  ui_digest="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${PROJECT_ROOT}/frontend/landet-cards.js")"
  curl -fsS --max-time 10 "http://${ha_ip}:${HA_HTTP_PORT:-8123}/local/proxmox-bootstrap/landet-cards-${ui_digest:0:12}.js" \
    | python3 -c 'import hashlib,sys; sys.exit(hashlib.sha256(sys.stdin.buffer.read()).hexdigest() != sys.argv[1])' "${ui_digest}" \
    || die 'Landet UI module is not served correctly'
  log_info 'Preview: https://ha.ostmarken.se/landet-view/live'
fi
