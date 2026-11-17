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

log_info "======================================"
log_info "STEP 10F - FRIGATE MQTT VALIDATION"
log_info "======================================"

FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
MQTT_CT_ID="${MQTT_CT_ID:-210}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USERNAME="${MQTT_USERNAME:-}"
MQTT_PASSWORD="${MQTT_PASSWORD:-}"
FRIGATE_CONFIG_FILE="${FRIGATE_CONFIG_FILE:-/opt/frigate/config/config.yml}"

VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0

record_error() {
  log_error "$1"
  ((VALIDATION_ERRORS+=1))
}

record_warn() {
  log_warn "$1"
  ((VALIDATION_WARNINGS+=1))
}

detect_ct_eth0_ipv4() {
  local ct_id="$1"

  pct exec "${ct_id}" -- ip -4 -o addr show dev eth0 2>/dev/null \
    | awk '{ split($4, addr, "/"); print addr[1]; exit }' || true
}

if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

for cmd in pct awk grep; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Required host command not found: ${cmd}"
    exit 1
  fi
done

if [[ ! "${FRIGATE_CT_ID}" =~ ^[0-9]+$ || ! "${MQTT_CT_ID}" =~ ^[0-9]+$ ]]; then
  log_error "Frigate and MQTT CT IDs must be numeric"
  exit 1
fi
if ! [[ "${MQTT_PORT}" =~ ^[0-9]{1,5}$ ]] || ((10#${MQTT_PORT:-0} < 1 || 10#${MQTT_PORT:-0} > 65535)); then
  log_error "MQTT_PORT must be an integer from 1 through 65535"
  exit 1
fi
if [[ -n "${MQTT_USERNAME}" && ( "${MQTT_USERNAME}" == *:* || "${MQTT_USERNAME}" == *$'\n'* || "${MQTT_USERNAME}" == *$'\r'* ) ]] \
  || [[ "${MQTT_PASSWORD}" == *$'\n'* || "${MQTT_PASSWORD}" == *$'\r'* ]]; then
  log_error "MQTT credentials contain unsupported characters"
  exit 1
fi

for ct_id in "${FRIGATE_CT_ID}" "${MQTT_CT_ID}"; do
  log_info "Checking CT ${ct_id}..."
  if ! CT_STATUS="$(pct status "${ct_id}" 2>&1)"; then
    record_error "Could not query status for CT ${ct_id}: ${CT_STATUS}"
  elif [[ "${CT_STATUS}" == *"status: running"* ]]; then
    log_info "CT ${ct_id} is running"
  else
    record_error "CT ${ct_id} is not running"
  fi
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Cannot continue because required CTs are not running"
  exit 1
fi

log_info "Detecting runtime LAN addresses..."
FRIGATE_IP="$(detect_ct_eth0_ipv4 "${FRIGATE_CT_ID}")"
MQTT_IP="$(detect_ct_eth0_ipv4 "${MQTT_CT_ID}")"

if [[ -n "${FRIGATE_IP}" ]]; then
  log_info "Detected Frigate CT IP: ${FRIGATE_IP}"
else
  record_error "Could not detect Frigate CT IPv4 address on eth0"
fi

if [[ -n "${MQTT_IP}" ]]; then
  log_info "Detected MQTT broker IP: ${MQTT_IP}:${MQTT_PORT}"
else
  record_error "Could not detect MQTT broker IPv4 address on eth0"
fi

if [[ -z "${MQTT_USERNAME}" || -z "${MQTT_PASSWORD}" ]]; then
  record_error "MQTT_USERNAME and MQTT_PASSWORD are required for authenticated validation"
fi

log_info "Checking Frigate MQTT config..."
if pct exec "${FRIGATE_CT_ID}" -- grep -qxF 'mqtt:' "${FRIGATE_CONFIG_FILE}" \
  && pct exec "${FRIGATE_CT_ID}" -- grep -qxF '  enabled: true' "${FRIGATE_CONFIG_FILE}" \
  && pct exec "${FRIGATE_CT_ID}" -- grep -qxF "  host: ${MQTT_IP}" "${FRIGATE_CONFIG_FILE}" \
  && pct exec "${FRIGATE_CT_ID}" -- grep -qxF "  port: ${MQTT_PORT}" "${FRIGATE_CONFIG_FILE}" \
  && pct exec "${FRIGATE_CT_ID}" -- grep -q '^  user:' "${FRIGATE_CONFIG_FILE}" \
  && pct exec "${FRIGATE_CT_ID}" -- grep -q '^  password:' "${FRIGATE_CONFIG_FILE}"; then
  log_info "Frigate config points to detected MQTT broker"
else
  record_error "Frigate config does not point to the detected MQTT broker"
fi

log_info "Checking Frigate container state..."
if pct exec "${FRIGATE_CT_ID}" -- docker ps --format '{{.Names}}' | grep -qx 'frigate'; then
  log_info "Frigate container is running"
else
  record_error "Frigate container is not running"
fi

log_info "Checking Mosquitto client tools in CT ${MQTT_CT_ID}..."
for cmd in mosquitto_sub timeout mktemp; do
  if pct exec "${MQTT_CT_ID}" -- bash -c "command -v '${cmd}' >/dev/null 2>&1"; then
    log_info "MQTT CT command found: ${cmd}"
  else
    record_error "Missing command inside MQTT CT ${MQTT_CT_ID}: ${cmd}"
  fi
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Cannot continue to MQTT subscription check"
  exit 1
fi

log_info "Creating an isolated temporary directory in CT ${MQTT_CT_ID}..."
if ! CLIENT_HOME="$(pct exec "${MQTT_CT_ID}" -- mktemp -d /tmp/step10f-frigate-mqtt.XXXXXX)"; then
  log_error "Could not create a unique MQTT validation directory"
  exit 1
fi
cleanup_mqtt_client() {
  [[ "${CLIENT_HOME:-}" == /tmp/step10f-frigate-mqtt.* ]] || return 0
  if ! pct exec "${MQTT_CT_ID}" -- rm -rf -- "${CLIENT_HOME}" >/dev/null 2>&1; then
    log_warn "Could not remove temporary MQTT validation directory: ${CLIENT_HOME}"
  fi
}
trap cleanup_mqtt_client EXIT
if [[ "${CLIENT_HOME}" != /tmp/step10f-frigate-mqtt.* ]]; then
  log_error "CT ${MQTT_CT_ID} returned an unexpected temporary directory path"
  exit 1
fi
printf '%s\n' "-h 127.0.0.1" "-p ${MQTT_PORT}" "-u ${MQTT_USERNAME}" "-P ${MQTT_PASSWORD}" \
  | pct exec "${MQTT_CT_ID}" -- bash -c \
    'umask 077; mkdir -p "$1"; cat > "$2"' bash \
    "${CLIENT_HOME}/.config" "${CLIENT_HOME}/.config/mosquitto_sub"

log_info "Checking retained Frigate availability message on MQTT..."
MQTT_MESSAGE="$(
  pct exec "${MQTT_CT_ID}" -- bash -c \
    'HOME="$1" XDG_CONFIG_HOME="$2" timeout 20 mosquitto_sub -t frigate/available -C 1 -W 15 2>"$3"' \
    bash "${CLIENT_HOME}" "${CLIENT_HOME}/.config" "${CLIENT_HOME}/mosquitto-sub.err" || true
)"

case "${MQTT_MESSAGE}" in
  online)
    log_info "Frigate published MQTT availability: online"
    ;;
  "")
    record_error "No retained MQTT availability message received on frigate/available"
    ;;
  *)
    record_warn "Unexpected Frigate MQTT availability payload (value suppressed)"
    ;;
esac

log_info "Checking Frigate logs since current container start for MQTT errors..."
FRIGATE_STARTED_AT="$(
  pct exec "${FRIGATE_CT_ID}" -- docker inspect --format '{{.State.StartedAt}}' frigate 2>/dev/null || true
)"

if [[ -n "${FRIGATE_STARTED_AT}" ]]; then
  RECENT_LOGS="$(pct exec "${FRIGATE_CT_ID}" -- docker logs --since "${FRIGATE_STARTED_AT}" --tail 1000 frigate 2>&1 || true)"
else
  record_warn "Could not determine Frigate container start time; falling back to last 200 log lines"
  RECENT_LOGS="$(pct exec "${FRIGATE_CT_ID}" -- docker logs --tail 200 frigate 2>&1 || true)"
fi

MQTT_ERROR_LINES="$(
  grep -iE 'mqtt.*(error|failed|refused|timeout|unreachable)' <<<"${RECENT_LOGS}" || true
)"
if [[ -n "${MQTT_ERROR_LINES}" ]]; then
  UNEXPECTED_MQTT_ERRORS="$(
    grep -viE 'mqtt.*error[[:space:]]*: mqtt disconnected' <<<"${MQTT_ERROR_LINES}" || true
  )"
  if [[ -n "${UNEXPECTED_MQTT_ERRORS}" ]]; then
    record_error "Frigate logs contain unexpected MQTT error-like messages"
  else
    record_warn "Frigate logs contain historical MQTT disconnects; current availability is online"
  fi
else
  log_info "No obvious MQTT errors found since current Frigate start"
fi

log_info "======================================"
log_info "FRIGATE MQTT VALIDATION SUMMARY"
log_info "======================================"
log_info "Validation warnings: ${VALIDATION_WARNINGS}"
log_info "Validation errors: ${VALIDATION_ERRORS}"

if [[ -n "${FRIGATE_IP}" ]]; then
  log_info "Frigate CT: ${FRIGATE_IP}"
fi

if [[ -n "${MQTT_IP}" ]]; then
  log_info "MQTT broker: ${MQTT_IP}:${MQTT_PORT}"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Frigate MQTT validation failed"
  exit 1
fi

if [[ "${VALIDATION_WARNINGS}" -gt 0 ]]; then
  log_warn "Frigate MQTT validation completed with warnings"
  exit 0
fi

log_info "Frigate MQTT validation completed successfully"
