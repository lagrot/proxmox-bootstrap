#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

log_info "=============================================="
log_info "STEP 10C - HOME ASSISTANT MQTT INTEGRATION"
log_info "=============================================="

HA_VM_ID="${HA_VM_ID:-100}"
HA_HTTP_PORT="${HA_HTTP_PORT:-8123}"
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

detect_ha_ip() {
  qm agent "${HA_VM_ID}" network-get-interfaces 2>/dev/null \
    | awk '
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

detect_ct_eth0_ipv4() {
  local ct_id="$1"

  pct exec "${ct_id}" -- ip -4 -o addr show dev eth0 2>/dev/null \
    | awk '{ split($4, addr, "/"); print addr[1]; exit }' || true
}

ha_api_get() {
  local ha_ip="$1"
  local path="$2"

  curl -fsS \
    -H "Authorization: Bearer ${HA_TOKEN}" \
    -H "Content-Type: application/json" \
    --max-time 10 \
    "http://${ha_ip}:${HA_HTTP_PORT}${path}"
}

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required host commands..."
for cmd in qm pct awk curl grep; do
  check_host_command "${cmd}"
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Missing required host commands"
  exit 1
fi

log_info "Checking Home Assistant VM ${HA_VM_ID}..."
if qm status "${HA_VM_ID}" 2>/dev/null | grep -q "status: running"; then
  log_info "VM ${HA_VM_ID} is running"
else
  record_error "VM ${HA_VM_ID} is not running"
fi

log_info "Detecting Home Assistant LAN IP..."
HA_IP="$(detect_ha_ip)"

if [[ -n "${HA_IP}" ]]; then
  log_info "Detected Home Assistant LAN IP: ${HA_IP}"
else
  record_error "Could not detect Home Assistant LAN IP from guest agent"
fi

log_info "Detecting MQTT broker LAN IP..."
MQTT_IP="$(detect_ct_eth0_ipv4 "${MQTT_CT_ID}")"

if [[ -n "${MQTT_IP}" ]]; then
  log_info "Detected MQTT broker IP: ${MQTT_IP}:${MQTT_PORT}"
else
  record_error "Could not detect MQTT broker IPv4 address on eth0"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Cannot continue until Home Assistant and MQTT are reachable"
  exit 1
fi

log_info "Checking Home Assistant HTTP endpoint..."
HTTP_CODE="$(
  curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://${HA_IP}:${HA_HTTP_PORT}" || true
)"

case "${HTTP_CODE}" in
  200|302|400|405)
    log_info "Home Assistant HTTP endpoint responded with HTTP ${HTTP_CODE}"
    ;;
  000|"")
    record_error "Home Assistant HTTP endpoint did not respond"
    ;;
  *)
    record_warn "Home Assistant HTTP endpoint returned unexpected HTTP ${HTTP_CODE}"
    ;;
esac

log_info "Checking optional Home Assistant API token..."
if [[ -n "${HA_TOKEN:-}" ]]; then
  if ha_api_get "${HA_IP}" "/api/" >/dev/null; then
    log_info "Home Assistant API token works"
  else
    record_error "HA_TOKEN was provided, but the Home Assistant API check failed"
  fi

  if ha_api_get "${HA_IP}" "/api/config" | grep -q '"components"'; then
    log_info "Home Assistant API config endpoint is available"
  else
    record_warn "Could not confirm Home Assistant API config details"
  fi
else
  record_warn "HA_TOKEN is not set; this script cannot verify the MQTT integration through the Home Assistant API"
fi

log_info "Manual Home Assistant MQTT integration target:"
log_info "Broker host: ${MQTT_IP}"
log_info "Broker port: ${MQTT_PORT}"
log_info "Username/password: leave blank for current bootstrap Mosquitto config"

if [[ -n "${HA_MQTT_INTEGRATION_CONFIRMED:-}" ]]; then
  log_info "HA_MQTT_INTEGRATION_CONFIRMED is set; recording MQTT integration as operator-confirmed"
else
  record_warn "After adding MQTT in Home Assistant, rerun with HA_MQTT_INTEGRATION_CONFIRMED=1 to record operator confirmation"
fi

log_info "=============================================="
log_info "HOME ASSISTANT MQTT INTEGRATION SUMMARY"
log_info "=============================================="
log_info "Validation warnings: ${VALIDATION_WARNINGS}"
log_info "Validation errors: ${VALIDATION_ERRORS}"
log_info "Home Assistant URL: http://${HA_IP}:${HA_HTTP_PORT}"
log_info "MQTT broker: ${MQTT_IP}:${MQTT_PORT}"

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Home Assistant MQTT integration check failed"
  exit 1
fi

if [[ "${VALIDATION_WARNINGS}" -gt 0 ]]; then
  log_warn "Home Assistant MQTT integration still needs operator confirmation"
  exit 0
fi

log_info "Home Assistant MQTT integration is operator-confirmed"
