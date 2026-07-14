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

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

for ct_id in "${FRIGATE_CT_ID}" "${MQTT_CT_ID}"; do
  log_info "Checking CT ${ct_id}..."
  if pct status "${ct_id}" 2>/dev/null | grep -q "status: running"; then
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
for cmd in mosquitto_sub timeout; do
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

CLIENT_HOME="/tmp/frigate-mqtt-validation-home"
trap 'pct exec "${MQTT_CT_ID}" -- rm -rf "${CLIENT_HOME}" >/dev/null 2>&1 || true' EXIT
printf '%s\n' "-h 127.0.0.1" "-p ${MQTT_PORT}" "-u ${MQTT_USERNAME}" "-P ${MQTT_PASSWORD}" \
  | pct exec "${MQTT_CT_ID}" -- bash -c "umask 077; mkdir -p '${CLIENT_HOME}/.config'; cat > '${CLIENT_HOME}/.config/mosquitto_sub'"

log_info "Checking retained Frigate availability message on MQTT..."
MQTT_MESSAGE="$(
  pct exec "${MQTT_CT_ID}" -- bash -c "HOME='${CLIENT_HOME}' XDG_CONFIG_HOME='${CLIENT_HOME}/.config' timeout 20 mosquitto_sub -t 'frigate/available' -C 1 -W 15 2>/tmp/frigate-mqtt-sub.err" || true
)"

case "${MQTT_MESSAGE}" in
  online)
    log_info "Frigate published MQTT availability: online"
    ;;
  "")
    record_error "No retained MQTT availability message received on frigate/available"
    ;;
  *)
    record_warn "Unexpected Frigate MQTT availability payload: ${MQTT_MESSAGE}"
    ;;
esac

log_info "Checking Frigate logs since current container start for MQTT errors..."
FRIGATE_STARTED_AT="$(
  pct exec "${FRIGATE_CT_ID}" -- docker inspect --format '{{.State.StartedAt}}' frigate 2>/dev/null || true
)"

if [[ -n "${FRIGATE_STARTED_AT}" ]]; then
  RECENT_LOGS="$(pct exec "${FRIGATE_CT_ID}" -- docker logs --since "${FRIGATE_STARTED_AT}" frigate 2>&1 || true)"
else
  record_warn "Could not determine Frigate container start time; falling back to last 200 log lines"
  RECENT_LOGS="$(pct exec "${FRIGATE_CT_ID}" -- docker logs --tail 200 frigate 2>&1 || true)"
fi

if grep -qiE 'mqtt.*(error|failed|refused|timeout|unreachable)' <<< "${RECENT_LOGS}"; then
  record_error "Recent Frigate logs contain MQTT error-like messages"
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
