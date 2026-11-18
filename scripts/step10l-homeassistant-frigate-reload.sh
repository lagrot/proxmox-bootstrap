#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"
if [[ -f "${PROJECT_ROOT}/config/local.conf" ]]; then
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/config/local.conf"
fi

log_info "================================================"
log_info "STEP 10L - HOME ASSISTANT FRIGATE INTEGRATION RELOAD"
log_info "================================================"

MODE="apply"
if [[ $# -gt 1 ]]; then
  log_error "Usage: $0 [--dry-run]"
  exit 2
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --help|-h) log_info "Usage: $0 [--dry-run]"; exit 0 ;;
    *) log_error "Usage: $0 [--dry-run]"; exit 2 ;;
  esac
fi

HA_TOKEN="${HA_TOKEN:-}"
TAPO_CAMERA_PROFILE="${TAPO_CAMERA_PROFILE:-c320ws}"
HA_FRIGATE_RELOAD_ENTITY="${HA_FRIGATE_RELOAD_ENTITY:-camera.${TAPO_C200_NAME:-tplink_c200_1}}"

case "${TAPO_CAMERA_PROFILE}" in
  c200)
    CAMERA_NAME="${TAPO_C200_NAME:-tplink_c200_1}"
    ;;
  c320ws)
    CAMERA_NAME="${TAPO_C320WS_NAME:-tplink_c320ws_1}"
    ;;
  *)
    log_error "Unsupported TAPO_CAMERA_PROFILE: ${TAPO_CAMERA_PROFILE} (use c200 or c320ws)"
    exit 1
    ;;
esac

if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

for command_name in qm curl python3 sleep; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    log_error "Required host command not found: ${command_name}"
    exit 1
  fi
done

if [[ ! "${HA_VM_ID}" =~ ^[1-9][0-9]*$ ]]; then
  log_error "HA_VM_ID must be a positive integer"
  exit 2
fi
if [[ ! "${HA_HTTP_PORT}" =~ ^[0-9]{1,5}$ ]] \
  || ((10#${HA_HTTP_PORT:-0} < 1 || 10#${HA_HTTP_PORT:-0} > 65535)); then
  log_error "HA_HTTP_PORT must be an integer from 1 through 65535"
  exit 2
fi
if [[ ! "${HA_FRIGATE_RELOAD_ENTITY}" =~ ^[a-z0-9_]+\.[a-z0-9_]+$ ]]; then
  log_error "HA_FRIGATE_RELOAD_ENTITY must be a valid lowercase entity ID"
  exit 2
fi
if [[ ! "${CAMERA_NAME}" =~ ^[A-Za-z0-9_]+$ ]]; then
  log_error "Camera name must contain only letters, numbers, and underscores"
  exit 2
fi
if [[ -z "${HA_TOKEN}" ]]; then
  log_error "HA_TOKEN is not set in config/local.conf"
  exit 1
fi
if [[ ! "${HA_TOKEN}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  log_error "HA_TOKEN contains unsupported characters"
  exit 2
fi
export -n HA_TOKEN

if [[ "${MODE}" == "dry-run" ]]; then
  log_info "Dry run: no qm agent request or Home Assistant API call will be made"
  log_info "Would detect Home Assistant VM ${HA_VM_ID} IP and reload ${HA_FRIGATE_RELOAD_ENTITY}"
  log_info "Would wait for camera.${CAMERA_NAME} to become available"
  log_info "No changes were made"
  exit 0
fi

HA_INTERFACES="$(qm agent "${HA_VM_ID}" network-get-interfaces 2>/dev/null || true)"
HA_IP="$(HA_INTERFACES="${HA_INTERFACES}" python3 - <<'PY'
import ipaddress
import json
import os

try:
    interfaces = json.loads(os.environ["HA_INTERFACES"])
except (json.JSONDecodeError, KeyError):
    raise SystemExit(0)
lan = (ipaddress.ip_network("10.0.0.0/8"),
       ipaddress.ip_network("172.16.0.0/12"),
       ipaddress.ip_network("192.168.0.0/16"))
tailscale = ipaddress.ip_network("100.64.0.0/10")
candidates = []
for interface in interfaces if isinstance(interfaces, list) else []:
    for item in interface.get("ip-addresses", []):
        if item.get("ip-address-type") != "ipv4":
            continue
        try:
            address = ipaddress.IPv4Address(item.get("ip-address", ""))
        except ipaddress.AddressValueError:
            continue
        if address.is_loopback or address.is_link_local or address.is_unspecified or address.is_multicast:
            continue
        if any(address in network for network in lan) and address not in ipaddress.ip_network("172.30.0.0/16"):
            candidates.append((0, str(address)))
        elif address in tailscale:
            candidates.append((1, str(address)))
for _, address in sorted(candidates):
    print(address)
    break
PY
)"

if [[ -z "${HA_IP}" ]]; then
  log_error "Could not detect the Home Assistant IPv4 address"
  exit 1
fi
if ! python3 - "${HA_IP}" <<'PY'
import ipaddress
import sys
try:
    address = ipaddress.IPv4Address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if not (address.is_loopback or address.is_link_local or address.is_unspecified or address.is_multicast) else 1)
PY
then
  log_error "Detected Home Assistant address is not a usable IPv4 address"
  exit 1
fi

ha_api_request() {
  local api_path="$1"
  local method="$2"
  local data="${3:-}"
  local -a curl_args=(-sS --max-time 10 --config - -X "${method}" \
    -H 'Content-Type: application/json')

  if [[ -n "${data}" ]]; then
    curl_args+=(--data "${data}")
  fi

  # The bearer token is supplied through curl's stdin config, never as a
  # command-line argument visible to other host processes.
  printf 'header = "Authorization: Bearer %s"\n' "${HA_TOKEN}" \
    | curl "${curl_args[@]}" -w $'\n%{http_code}' \
      "http://${HA_IP}:${HA_HTTP_PORT}${api_path}" || true
}

log_info "Resolving the Home Assistant config entry for ${HA_FRIGATE_RELOAD_ENTITY}..."
ENTRY_RESPONSE="$(ha_api_request "/api/template" POST \
  "{\"template\":\"{{ config_entry_id('${HA_FRIGATE_RELOAD_ENTITY}') }}\"}")"
ENTRY_CODE="${ENTRY_RESPONSE##*$'\n'}"
ENTRY_BODY="${ENTRY_RESPONSE%$'\n'*}"

if [[ "${ENTRY_CODE}" != "200" ]]; then
  log_error "Home Assistant config-entry lookup returned HTTP ${ENTRY_CODE}"
  exit 1
fi

ENTRY_ID="$(python3 -c 'import sys; print(sys.stdin.read().strip())' <<< "${ENTRY_BODY}")"
if [[ ! "${ENTRY_ID}" =~ ^[A-Za-z0-9_-]{16,64}$ ]]; then
  log_error "Home Assistant returned an invalid config-entry ID for ${HA_FRIGATE_RELOAD_ENTITY}"
  exit 1
fi

log_info "Reloading the Home Assistant Frigate integration..."
RELOAD_RESPONSE="$(ha_api_request "/api/services/homeassistant/reload_config_entry" POST \
  "{\"entry_id\":\"${ENTRY_ID}\"}")"
RELOAD_CODE="${RELOAD_RESPONSE##*$'\n'}"

if [[ "${RELOAD_CODE}" != "200" ]]; then
  log_error "Home Assistant Frigate integration reload returned HTTP ${RELOAD_CODE}"
  exit 1
fi

TARGET_ENTITY="camera.${CAMERA_NAME}"
log_info "Waiting for ${TARGET_ENTITY}..."

for _attempt in {1..10}; do
  CAMERA_RESPONSE="$(ha_api_request "/api/states/${TARGET_ENTITY}" GET)"
  CAMERA_CODE="${CAMERA_RESPONSE##*$'\n'}"
  CAMERA_BODY="${CAMERA_RESPONSE%$'\n'*}"
  if [[ "${CAMERA_CODE}" == "200" ]]; then
    CAMERA_STATE="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("state", ""))' \
      <<< "${CAMERA_BODY}" 2>/dev/null || true)"
  else
    CAMERA_STATE=""
  fi

  if [[ -n "${CAMERA_STATE}" && "${CAMERA_STATE}" != "unknown" && "${CAMERA_STATE}" != "unavailable" ]]; then
    log_info "Home Assistant reports ${TARGET_ENTITY} state: ${CAMERA_STATE}"
    log_info "Home Assistant Frigate integration reload completed successfully"
    exit 0
  fi

  sleep 3
done

log_error "Home Assistant did not expose an available ${TARGET_ENTITY} entity after reload"
exit 1
