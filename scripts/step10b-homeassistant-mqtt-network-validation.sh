#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

log_info "======================================"
log_info "STEP 10B - HOME ASSISTANT MQTT NETWORK"
log_info "======================================"

HA_VM_ID="${HA_VM_ID:-100}"
HA_VM_BRIDGE="${HA_VM_BRIDGE:-${PROXMOX_BRIDGE:-vmbr0}}"
MQTT_CT_ID="${MQTT_CT_ID:-210}"
MQTT_CT_HOSTNAME="${MQTT_CT_HOSTNAME:-mqtt-core}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_CT_BRIDGE="${MQTT_CT_BRIDGE:-${PROXMOX_BRIDGE:-vmbr0}}"

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

detect_ha_ip() {
  qm agent "${HA_VM_ID}" network-get-interfaces 2>/dev/null \
    | awk '
        /"name" :/ {
          name=$3
          gsub(/[",]/, "", name)
        }
        /"ip-address" :/ {
          ip=$3
          gsub(/[",]/, "", ip)
        }
        /"ip-address-type" : "ipv4"/ {
          if (ip !~ /^127\./ && ip !~ /^169\.254\./ && ip !~ /^172\.30\./) {
            print ip
            exit
          }
        }
      ' || true
}

tcp_connect() {
  local host="$1"
  local port="$2"

  timeout 5 bash -c ":</dev/tcp/${host}/${port}" >/dev/null 2>&1
}

detect_ct_ipv4() {
  pct exec "${MQTT_CT_ID}" -- hostname -I 2>/dev/null \
    | awk '
        {
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
              print $i
              exit
            }
          }
        }
      ' || true
}

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required host commands..."
for cmd in pct qm grep awk timeout bash; do
  check_host_command "${cmd}"
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Missing required host commands"
  exit 1
fi

log_info "Checking Home Assistant VM ${HA_VM_ID}..."
if qm config "${HA_VM_ID}" >/dev/null 2>&1; then
  log_info "VM ${HA_VM_ID} exists"
else
  record_error "VM ${HA_VM_ID} does not exist"
fi

if qm status "${HA_VM_ID}" 2>/dev/null | grep -q "status: running"; then
  log_info "VM ${HA_VM_ID} is running"
else
  record_error "VM ${HA_VM_ID} is not running"
fi

HA_VM_CONFIG="$(qm config "${HA_VM_ID}" 2>/dev/null || true)"

if grep -q "^net0: .*bridge=${HA_VM_BRIDGE}" <<< "${HA_VM_CONFIG}"; then
  log_info "Home Assistant VM net0 is attached to ${HA_VM_BRIDGE}"
else
  record_error "Home Assistant VM net0 is not attached to ${HA_VM_BRIDGE}"
fi

log_info "Detecting Home Assistant LAN IP..."
HA_VM_IP="$(detect_ha_ip)"

if [[ -n "${HA_VM_IP}" ]]; then
  log_info "Detected Home Assistant LAN IP: ${HA_VM_IP}"
else
  record_error "Could not detect Home Assistant LAN IP from guest agent"
fi

log_info "Checking MQTT CT ${MQTT_CT_ID}..."
if pct config "${MQTT_CT_ID}" >/dev/null 2>&1; then
  log_info "CT ${MQTT_CT_ID} exists"
else
  record_error "CT ${MQTT_CT_ID} does not exist"
fi

if pct status "${MQTT_CT_ID}" 2>/dev/null | grep -q "status: running"; then
  log_info "CT ${MQTT_CT_ID} is running"
else
  record_error "CT ${MQTT_CT_ID} is not running"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Cannot continue because required guests are not ready"
  exit 1
fi

MQTT_CT_CONFIG="$(pct config "${MQTT_CT_ID}")"

if grep -q "^hostname: ${MQTT_CT_HOSTNAME}$" <<< "${MQTT_CT_CONFIG}"; then
  log_info "MQTT CT hostname is ${MQTT_CT_HOSTNAME}"
else
  record_warn "MQTT CT hostname does not match ${MQTT_CT_HOSTNAME}"
fi

if grep -q "^net0: .*bridge=${MQTT_CT_BRIDGE}" <<< "${MQTT_CT_CONFIG}"; then
  log_info "MQTT CT net0 is attached to ${MQTT_CT_BRIDGE}"
else
  record_error "MQTT CT net0 is not attached to ${MQTT_CT_BRIDGE}"
fi

MQTT_CT_IP="$(detect_ct_ipv4)"

if [[ -n "${MQTT_CT_IP}" ]]; then
  log_info "Detected MQTT CT IP: ${MQTT_CT_IP}"
else
  record_error "Could not detect MQTT CT IPv4 address"
fi

log_info "Checking Home Assistant and MQTT network placement..."
if [[ "${HA_VM_BRIDGE}" == "${MQTT_CT_BRIDGE}" ]]; then
  log_info "Home Assistant and MQTT are configured on bridge ${HA_VM_BRIDGE}"
else
  record_error "Home Assistant bridge ${HA_VM_BRIDGE} differs from MQTT bridge ${MQTT_CT_BRIDGE}"
fi

if [[ -n "${HA_VM_IP}" && -n "${MQTT_CT_IP}" ]]; then
  log_info "Detected Home Assistant and MQTT IPv4 addresses: ${HA_VM_IP} -> ${MQTT_CT_IP}"
else
  record_error "Cannot compare Home Assistant and MQTT runtime addresses because one is missing"
fi

log_info "Checking Mosquitto listener inside CT ${MQTT_CT_ID}..."
if pct exec "${MQTT_CT_ID}" -- ss -ltnp | grep -q ":${MQTT_PORT}"; then
  log_info "Mosquitto is listening on TCP port ${MQTT_PORT}"
else
  record_error "Mosquitto is not listening on TCP port ${MQTT_PORT}"
fi

log_info "Checking MQTT TCP reachability from the Proxmox LAN side..."
if [[ -n "${MQTT_CT_IP}" ]] && tcp_connect "${MQTT_CT_IP}" "${MQTT_PORT}"; then
  log_info "MQTT broker is reachable at ${MQTT_CT_IP}:${MQTT_PORT}"
else
  record_error "Could not connect to MQTT broker at ${MQTT_CT_IP}:${MQTT_PORT}"
fi

log_info "======================================"
log_info "HOME ASSISTANT MQTT NETWORK SUMMARY"
log_info "======================================"
log_info "Validation warnings: ${VALIDATION_WARNINGS}"
log_info "Validation errors: ${VALIDATION_ERRORS}"
if [[ -n "${HA_VM_IP}" ]]; then
  log_info "Home Assistant: ${HA_VM_IP}"
fi

if [[ -n "${MQTT_CT_IP}" ]]; then
  log_info "MQTT broker: ${MQTT_CT_IP}:${MQTT_PORT}"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Home Assistant MQTT network validation failed"
  exit 1
fi

if [[ "${VALIDATION_WARNINGS}" -gt 0 ]]; then
  log_warn "Home Assistant MQTT network validation completed with warnings"
  exit 0
fi

log_info "Home Assistant MQTT network validation completed successfully"
