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

for command_name in qm awk curl python3; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    log_error "Required host command not found: ${command_name}"
    exit 1
  fi
done

if [[ -z "${HA_TOKEN}" ]]; then
  log_error "HA_TOKEN is not set in config/local.conf"
  exit 1
fi

HA_IP="$(
  qm agent "${HA_VM_ID}" network-get-interfaces 2>/dev/null \
    | awk '
      /"ip-address" :/ { ip=$3; gsub(/[",]/, "", ip) }
      /"ip-address-type" : "ipv4"/ {
        if (ip !~ /^127\./ && ip !~ /^169\.254\./ && ip !~ /^172\.30\./) { print ip; exit }
      }
    ' || true
)"

if [[ -z "${HA_IP}" ]]; then
  log_error "Could not detect the Home Assistant IPv4 address"
  exit 1
fi

log_info "Reloading the Home Assistant Frigate integration..."
RELOAD_CODE="$(
  curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${HA_TOKEN}" \
    -H 'Content-Type: application/json' \
    --data "{\"entity_id\":\"${HA_FRIGATE_RELOAD_ENTITY}\"}" \
    "http://${HA_IP}:${HA_HTTP_PORT}/api/services/homeassistant/reload_config_entry" || true
)"

if [[ "${RELOAD_CODE}" != "200" ]]; then
  log_error "Home Assistant Frigate integration reload returned HTTP ${RELOAD_CODE}"
  exit 1
fi

TARGET_ENTITY="camera.${CAMERA_NAME}"
log_info "Waiting for ${TARGET_ENTITY}..."

for _attempt in {1..10}; do
  CAMERA_STATE="$(
    curl -sS -H "Authorization: Bearer ${HA_TOKEN}" --max-time 10 \
      "http://${HA_IP}:${HA_HTTP_PORT}/api/states/${TARGET_ENTITY}" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state", ""))' \
      2>/dev/null || true
  )"

  if [[ -n "${CAMERA_STATE}" && "${CAMERA_STATE}" != "unknown" && "${CAMERA_STATE}" != "unavailable" ]]; then
    log_info "Home Assistant reports ${TARGET_ENTITY} state: ${CAMERA_STATE}"
    log_info "Home Assistant Frigate integration reload completed successfully"
    exit 0
  fi

  sleep 3
done

log_error "Home Assistant did not expose an available ${TARGET_ENTITY} entity after reload"
exit 1
