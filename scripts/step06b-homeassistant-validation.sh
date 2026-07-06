#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

log_info "======================================"
log_info "STEP 06B - HOME ASSISTANT VALIDATION"
log_info "======================================"

HA_VM_ID="${HA_VM_ID:-100}"
HA_VM_NAME="${HA_VM_NAME:-homeassistant}"
HA_VM_BRIDGE="${HA_VM_BRIDGE:-vmbr0}"
HA_HTTP_PORT="${HA_HTTP_PORT:-8123}"

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

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required host commands..."
for cmd in qm grep awk curl; do
  check_host_command "${cmd}"
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Missing required host commands"
  exit 1
fi

log_info "Checking whether VM ${HA_VM_ID} exists..."
if qm config "${HA_VM_ID}" >/dev/null 2>&1; then
  log_info "VM ${HA_VM_ID} exists"
else
  record_error "VM ${HA_VM_ID} does not exist"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Cannot continue because VM ${HA_VM_ID} is missing"
  exit 1
fi

VM_CONFIG="$(qm config "${HA_VM_ID}")"

log_info "Checking VM name..."
if grep -q "^name: ${HA_VM_NAME}$" <<< "${VM_CONFIG}"; then
  log_info "VM name is ${HA_VM_NAME}"
else
  record_warn "VM name is not ${HA_VM_NAME}"
fi

log_info "Checking whether VM ${HA_VM_ID} is running..."
if qm status "${HA_VM_ID}" | grep -q "status: running"; then
  log_info "VM ${HA_VM_ID} is running"
else
  record_error "VM ${HA_VM_ID} is not running"
fi

log_info "Checking VM firmware and machine type..."
if grep -q "^bios: ovmf$" <<< "${VM_CONFIG}"; then
  log_info "VM uses OVMF/UEFI firmware"
else
  record_error "VM does not use OVMF/UEFI firmware"
fi

if grep -q "^machine: q35$" <<< "${VM_CONFIG}"; then
  log_info "VM uses q35 machine type"
else
  record_warn "VM does not use q35 machine type"
fi

log_info "Checking boot disk configuration..."
if grep -q "^boot: order=scsi0" <<< "${VM_CONFIG}"; then
  log_info "VM boots from scsi0"
else
  record_error "VM boot order does not start with scsi0"
fi

if grep -q "^scsi0:" <<< "${VM_CONFIG}"; then
  log_info "VM has scsi0 disk attached"
else
  record_error "VM does not have scsi0 disk attached"
fi

if grep -q "^efidisk0:" <<< "${VM_CONFIG}"; then
  log_info "VM has EFI disk attached"
else
  record_error "VM does not have EFI disk attached"
fi

log_info "Checking network bridge configuration..."
if grep -q "^net0: .*bridge=${HA_VM_BRIDGE}" <<< "${VM_CONFIG}"; then
  log_info "VM net0 is attached to ${HA_VM_BRIDGE}"
else
  record_error "VM net0 is not attached to ${HA_VM_BRIDGE}"
fi

log_info "Checking onboot setting..."
if grep -q "^onboot: 1$" <<< "${VM_CONFIG}"; then
  log_info "VM is configured to start on boot"
else
  record_warn "VM is not configured to start on boot"
fi

log_info "Checking guest agent configuration..."
if grep -q "^agent: enabled=1" <<< "${VM_CONFIG}"; then
  log_info "Guest agent is enabled in VM config"
else
  record_warn "Guest agent is not enabled in VM config"
fi

log_info "Checking guest agent response..."
if qm agent "${HA_VM_ID}" ping >/dev/null 2>&1; then
  log_info "Guest agent responds"
else
  record_warn "Guest agent does not respond yet"
fi

log_info "Detecting Home Assistant LAN IP..."
HA_VM_IP="$(
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
)"

if [[ -n "${HA_VM_IP}" ]]; then
  log_info "Detected Home Assistant LAN IP: ${HA_VM_IP}"
else
  record_warn "Could not detect Home Assistant LAN IP from guest agent"
fi

log_info "Checking Home Assistant HTTP endpoint..."
if [[ -n "${HA_VM_IP}" ]]; then
  HTTP_CODE="$(
    curl -s -o /dev/null -w "%{http_code}" "http://${HA_VM_IP}:${HA_HTTP_PORT}" || true
  )"

  case "${HTTP_CODE}" in
    200|302|400|405)
      log_info "Home Assistant HTTP endpoint responded with HTTP ${HTTP_CODE}"
      ;;
    000)
      record_error "Home Assistant HTTP endpoint did not respond"
      ;;
    *)
      record_warn "Home Assistant HTTP endpoint returned unexpected HTTP ${HTTP_CODE}"
      ;;
  esac
else
  record_warn "Skipping HTTP endpoint check because no LAN IP was detected"
fi

log_info "======================================"
log_info "HOME ASSISTANT VALIDATION SUMMARY"
log_info "======================================"
log_info "Validation warnings: ${VALIDATION_WARNINGS}"
log_info "Validation errors: ${VALIDATION_ERRORS}"

if [[ -n "${HA_VM_IP}" ]]; then
  log_info "Home Assistant URL: http://${HA_VM_IP}:${HA_HTTP_PORT}"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Home Assistant validation failed"
  exit 1
fi

if [[ "${VALIDATION_WARNINGS}" -gt 0 ]]; then
  log_warn "Home Assistant validation completed with warnings"
  exit 0
fi

log_info "Home Assistant validation completed successfully"
