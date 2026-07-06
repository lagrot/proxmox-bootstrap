#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

log_info "======================================"
log_info "STEP 05B - MQTT VALIDATION"
log_info "======================================"

MQTT_CT_ID="${MQTT_CT_ID:-210}"
MQTT_PORT="${MQTT_PORT:-1883}"

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

check_host_command() {
  local cmd="$1"

  if command -v "${cmd}" >/dev/null 2>&1; then
    log_info "Host command found: ${cmd}"
  else
    record_error "Required host command not found: ${cmd}"
  fi
}

check_ct_command() {
  local cmd="$1"

  if pct exec "${MQTT_CT_ID}" -- bash -c "command -v '${cmd}' >/dev/null 2>&1"; then
    log_info "CT command found: ${cmd}"
  else
    record_error "Required command not found inside CT ${MQTT_CT_ID}: ${cmd}"
  fi
}

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required host commands..."
for cmd in pct grep awk; do
  check_host_command "${cmd}"
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Missing required host commands"
  exit 1
fi

log_info "Checking whether CT ${MQTT_CT_ID} exists..."
if pct config "${MQTT_CT_ID}" >/dev/null 2>&1; then
  log_info "CT ${MQTT_CT_ID} exists"
else
  record_error "CT ${MQTT_CT_ID} does not exist"
fi

log_info "Checking whether CT ${MQTT_CT_ID} is running..."
if pct status "${MQTT_CT_ID}" | grep -q "status: running"; then
  log_info "CT ${MQTT_CT_ID} is running"
else
  record_error "CT ${MQTT_CT_ID} is not running"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Cannot continue because CT ${MQTT_CT_ID} is not ready"
  exit 1
fi

log_info "Checking useful commands inside CT ${MQTT_CT_ID}..."
for cmd in systemctl ss mosquitto mosquitto_pub mosquitto_sub; do
  check_ct_command "${cmd}"
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Missing required commands inside CT ${MQTT_CT_ID}"
  exit 1
fi

log_info "Checking Mosquitto service state..."
if pct exec "${MQTT_CT_ID}" -- systemctl is-active --quiet mosquitto; then
  log_info "Mosquitto service is active"
else
  record_error "Mosquitto service is not active"
fi

log_info "Checking Mosquitto enablement..."
if pct exec "${MQTT_CT_ID}" -- systemctl is-enabled --quiet mosquitto; then
  log_info "Mosquitto service is enabled"
else
  record_warn "Mosquitto service is not enabled"
fi

log_info "Checking MQTT listener on TCP ${MQTT_PORT}..."
if pct exec "${MQTT_CT_ID}" -- ss -ltnp | grep -q ":${MQTT_PORT}"; then
  log_info "Mosquitto is listening on TCP port ${MQTT_PORT}"
else
  record_error "Mosquitto is not listening on TCP port ${MQTT_PORT}"
fi

log_info "Checking Mosquitto homelab config..."
if pct exec "${MQTT_CT_ID}" -- test -f /etc/mosquitto/conf.d/homelab.conf; then
  log_info "homelab.conf exists"
else
  record_error "/etc/mosquitto/conf.d/homelab.conf does not exist"
fi

log_info "Checking for duplicate persistence_location config..."
PERSISTENCE_COUNT="$(
  pct exec "${MQTT_CT_ID}" -- bash -c "grep -R '^persistence_location' /etc/mosquitto/mosquitto.conf /etc/mosquitto/conf.d/*.conf 2>/dev/null | wc -l" || echo "0"
)"

if [[ "${PERSISTENCE_COUNT}" -gt 1 ]]; then
  record_error "Duplicate persistence_location entries found: ${PERSISTENCE_COUNT}"
else
  log_info "No duplicate persistence_location entries found"
fi

log_info "Running local MQTT publish/subscribe test..."
TEST_TOPIC="homelab/validation"
TEST_MESSAGE="mqtt-validation-ok-$(date +%s)"

if pct exec "${MQTT_CT_ID}" -- bash -c "
  timeout 5 mosquitto_sub -h 127.0.0.1 -p '${MQTT_PORT}' -t '${TEST_TOPIC}' -C 1 > /tmp/mqtt-validation.out &
  sub_pid=\$!
  sleep 1
  mosquitto_pub -h 127.0.0.1 -p '${MQTT_PORT}' -t '${TEST_TOPIC}' -m '${TEST_MESSAGE}'
  wait \${sub_pid}
  grep -qx '${TEST_MESSAGE}' /tmp/mqtt-validation.out
  rm -f /tmp/mqtt-validation.out
"; then
  log_info "Local MQTT publish/subscribe test succeeded"
else
  record_error "Local MQTT publish/subscribe test failed"
fi

log_info "Checking recent Mosquitto logs for errors..."
RECENT_LOGS="$(pct exec "${MQTT_CT_ID}" -- journalctl -u mosquitto --no-pager -n 100 2>&1 || true)"

if grep -qiE 'error|failed|duplicate' <<< "${RECENT_LOGS}"; then
  record_warn "Recent Mosquitto logs contain error-like messages; review journalctl if needed"
else
  log_info "No obvious recent Mosquitto errors found"
fi

MQTT_CT_IP="$(
  pct exec "${MQTT_CT_ID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true
)"

log_info "======================================"
log_info "MQTT VALIDATION SUMMARY"
log_info "======================================"
log_info "Validation warnings: ${VALIDATION_WARNINGS}"
log_info "Validation errors: ${VALIDATION_ERRORS}"

if [[ -n "${MQTT_CT_IP}" ]]; then
  log_info "MQTT broker: ${MQTT_CT_IP}:${MQTT_PORT}"
else
  record_warn "Could not determine MQTT CT IP address"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "MQTT validation failed"
  exit 1
fi

if [[ "${VALIDATION_WARNINGS}" -gt 0 ]]; then
  log_warn "MQTT validation completed with warnings"
  exit 0
fi

log_info "MQTT validation completed successfully"
