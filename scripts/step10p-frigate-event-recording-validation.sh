#!/usr/bin/env bash
# Validate Frigate's effective event-recording policy without changing guests.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if (( $# > 1 )); then printf 'Too many arguments\n' >&2; exit 2; fi
case "${1:-}" in
  "") ;;
  -h|--help)
    cat <<EOF
Usage: $0

Read Frigate's effective config and recent container status/logs. This is a
read-only validation; the API response is checked in host memory and is not
written to a temporary file. No camera activity is required.
EOF
    exit 0
    ;;
  *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"
if [[ -f "${PROJECT_ROOT}/config/local.conf" ]]; then
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/config/local.conf"
fi

log_info "===================================================="
log_info "STEP 10P - FRIGATE EVENT RECORDING VALIDATION"
log_info "===================================================="

FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
FRIGATE_INTERNAL_PORT="${FRIGATE_INTERNAL_PORT:-5000}"
EVENT_RECORDING_DAYS="${FRIGATE_EVENT_RECORDING_DAYS:-10}"
EVENT_PRE_CAPTURE_SECONDS="${FRIGATE_EVENT_PRE_CAPTURE_SECONDS:-5}"
EVENT_POST_CAPTURE_SECONDS="${FRIGATE_EVENT_POST_CAPTURE_SECONDS:-5}"
CAMERA_NAMES=(
  "${TAPO_C200_NAME:-${TAPO_CAMERA_NAME:-tplink_c200_1}}"
  "${TAPO_C320WS_NAME:-tplink_c320ws_1}"
)
CONFIG_VALIDATOR="${PROJECT_ROOT}/lib/frigate-event-recording-validation.py"
VALIDATION_ERRORS=0

record_error() {
  log_error "$1"
  ((VALIDATION_ERRORS+=1))
}

if [[ "${EUID}" -ne 0 ]]; then log_error "This script must be run as root"; exit 1; fi
for command_name in pct curl python3 grep awk sed; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    log_error "Required host command not found: ${command_name}"; exit 1
  fi
done
if [[ ! -f "${CONFIG_VALIDATOR}" ]]; then log_error "Missing API config validator: ${CONFIG_VALIDATOR}"; exit 1; fi
if [[ ! "${FRIGATE_CT_ID}" =~ ^[0-9]+$ ]]; then log_error "Frigate CT ID must be numeric"; exit 1; fi
if [[ ! "${FRIGATE_INTERNAL_PORT}" =~ ^[0-9]{1,5}$ ]] \
  || (( 10#${FRIGATE_INTERNAL_PORT} < 1 || 10#${FRIGATE_INTERNAL_PORT} > 65535 )); then
  log_error "FRIGATE_INTERNAL_PORT must be an integer from 1 through 65535"; exit 1
fi
for value_name in EVENT_RECORDING_DAYS EVENT_PRE_CAPTURE_SECONDS EVENT_POST_CAPTURE_SECONDS; do
  if [[ ! "${!value_name}" =~ ^[0-9]{1,6}$ ]]; then
    log_error "${value_name} must be a non-negative integer"; exit 1
  fi
done
if [[ "${EVENT_RECORDING_DAYS}" =~ ^0+$ ]]; then log_error "EVENT_RECORDING_DAYS must be greater than zero"; exit 1; fi
for camera_name in "${CAMERA_NAMES[@]}"; do
  if [[ ! "${camera_name}" =~ ^[A-Za-z0-9_]+$ ]]; then
    log_error "Invalid Frigate camera name: ${camera_name}"; exit 1
  fi
done
if [[ "${CAMERA_NAMES[0]}" == "${CAMERA_NAMES[1]}" ]]; then
  log_error "The two Frigate camera names must be different"; exit 1
fi

if ! CT_STATUS="$(pct status "${FRIGATE_CT_ID}" 2>&1)"; then
  log_error "Could not query status for CT ${FRIGATE_CT_ID}: ${CT_STATUS}"; exit 1
fi
if [[ "${CT_STATUS}" != *"status: running"* ]]; then
  log_error "CT ${FRIGATE_CT_ID} is not running"; exit 1
fi

FRIGATE_IP="$(pct exec "${FRIGATE_CT_ID}" -- ip -4 -o addr show dev eth0 2>/dev/null \
  | awk '{ split($4, addr, "/"); print addr[1]; exit }' || true)"
if [[ ! "${FRIGATE_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  log_error "Could not detect Frigate CT IPv4 address"; exit 1
fi

log_info "Checking Frigate container health..."
if ! pct exec "${FRIGATE_CT_ID}" -- docker ps --format '{{.Names}}' | grep -qx frigate; then
  record_error "Frigate container is not running"
fi

HEALTH="$(pct exec "${FRIGATE_CT_ID}" -- docker inspect \
  --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' frigate 2>/dev/null || true)"
if [[ "${HEALTH}" == healthy ]]; then
  log_info "Frigate container is healthy"
else
  record_error "Unexpected Frigate container health: ${HEALTH:-unknown}"
fi

log_info "Checking effective Frigate event retention through the API..."
CONFIG_JSON="$(curl -fsS --max-time 15 "http://${FRIGATE_IP}:${FRIGATE_INTERNAL_PORT}/api/config" || true)"
if [[ -z "${CONFIG_JSON}" ]]; then
  record_error "Could not read effective Frigate config"
elif printf '%s' "${CONFIG_JSON}" | python3 "${CONFIG_VALIDATOR}" \
  "${EVENT_RECORDING_DAYS}" "${EVENT_PRE_CAPTURE_SECONDS}" \
  "${EVENT_POST_CAPTURE_SECONDS}" "${CAMERA_NAMES[@]}"; then
  log_info "Both cameras use event-only video retention"
else
  record_error "Effective event recording policy does not match"
fi

log_info "Checking the last hour of Frigate logs for config/recording failures..."
RECENT_LOGS="$(pct exec "${FRIGATE_CT_ID}" -- docker logs --since 1h frigate 2>&1 || true)"
# Frigate log lines identify the logger before `ERROR :`. Strip that metadata
# first so a `record ERROR` logger prefix alone is not treated as a message.
ERROR_MESSAGES="$(sed -nE 's/^.* (ERROR|FATAL) : //p' <<< "${RECENT_LOGS}")"
if grep -qiE '(^|[^[:alnum:]_])config(uration)?\]?[[:space:]]+(ERROR|FATAL)[[:space:]]*:' \
  <<< "${RECENT_LOGS}" \
  || grep -qiE '((config(uration)?|record(ing)?).*(error|invalid|failed)|(error|invalid|failed).*(config(uration)?|record(ing)?))' \
    <<< "${ERROR_MESSAGES}"; then
  record_error "Frigate logs contain configuration or recording errors"
else
  log_info "No configuration or recording errors found in the last hour"
fi

log_info "============================================"
log_info "FRIGATE EVENT RECORDING VALIDATION SUMMARY"
log_info "============================================"
log_info "Validation errors: ${VALIDATION_ERRORS}"
if (( VALIDATION_ERRORS > 0 )); then
  log_error "Frigate event recording validation failed"; exit 1
fi
log_info "Frigate event-only recording validation completed successfully"
