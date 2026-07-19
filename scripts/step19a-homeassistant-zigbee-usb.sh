#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

HA_VM_ID="${HA_VM_ID:-100}"
ZIGBEE_USB_ID="${ZIGBEE_USB_ID:-10c4:ea60}"
ZIGBEE_USB_SERIAL="${ZIGBEE_USB_SERIAL:-008d95d7e99def11be87cba661ce3355}"
VM_CONFIG_FILE="/etc/pve/qemu-server/${HA_VM_ID}.conf"
BACKUP_DIR="/var/backups/proxmox-bootstrap/vm-configs"

log_info "=============================================="
log_info "STEP 19A - HOME ASSISTANT ZIGBEE USB"
log_info "=============================================="

[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in install lsusb qm; do command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"; done
qm config "${HA_VM_ID}" >/dev/null 2>&1 || die "VM ${HA_VM_ID} does not exist"

mapfile -t matching_devices < <(lsusb -d "${ZIGBEE_USB_ID}")
(( ${#matching_devices[@]} == 1 )) || die "Expected exactly one USB ${ZIGBEE_USB_ID} device; found ${#matching_devices[@]}"

vm_config="$(qm config "${HA_VM_ID}")"
if grep -qE "^usb[0-4]: host=${ZIGBEE_USB_ID}(,|$)" <<<"${vm_config}"; then
  log_info "Zigbee USB passthrough is already configured"
  exit 0
fi

serial_path="$(find /dev/serial/by-id -maxdepth 1 -type l -name "*${ZIGBEE_USB_SERIAL}*" -print -quit 2>/dev/null || true)"
[[ -n "${serial_path}" ]] || die "Sonoff serial identity ${ZIGBEE_USB_SERIAL} was not found"
log_info "Detected Sonoff ZBDongle-P: ${serial_path}"

usb_slot=""
for candidate in usb0 usb1 usb2 usb3 usb4; do
  if ! grep -q "^${candidate}:" <<<"${vm_config}"; then
    usb_slot="${candidate}"
    break
  fi
done
[[ -n "${usb_slot}" ]] || die "No free VM USB slot is available"

was_running=0
if [[ "$(qm status "${HA_VM_ID}")" == "status: running" ]]; then
  was_running=1
  log_info "Shutting down Home Assistant VM ${HA_VM_ID}..."
  qm shutdown "${HA_VM_ID}" --timeout 120
fi
[[ "$(qm status "${HA_VM_ID}")" == "status: stopped" ]] || die "VM ${HA_VM_ID} did not stop"

backup_file="${BACKUP_DIR}/${HA_VM_ID}.conf.before-zigbee-$(date +%Y%m%d%H%M%S)"
install -D -m 0600 "${VM_CONFIG_FILE}" "${backup_file}"
log_info "Saved stopped-VM configuration backup: ${backup_file}"

log_info "Assigning ${ZIGBEE_USB_ID} as ${usb_slot}..."
qm set "${HA_VM_ID}" "--${usb_slot}" "host=${ZIGBEE_USB_ID}"

if [[ "${was_running}" -eq 1 ]]; then
  log_info "Starting Home Assistant VM ${HA_VM_ID}..."
  qm start "${HA_VM_ID}"
  for _ in $(seq 1 60); do
    if qm agent "${HA_VM_ID}" ping >/dev/null 2>&1; then
      log_info "Home Assistant guest agent responds"
      exit 0
    fi
    sleep 5
  done
  die "Home Assistant guest agent did not respond within five minutes"
fi

log_info "Zigbee USB passthrough configured; VM ${HA_VM_ID} remains stopped"
