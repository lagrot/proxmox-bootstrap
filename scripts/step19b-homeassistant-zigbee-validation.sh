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
HA_HTTP_PORT="${HA_HTTP_PORT:-8123}"
HA_TOKEN="${HA_TOKEN:-}"
VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0

record_error() { log_error "$1"; ((VALIDATION_ERRORS+=1)); }
record_warn() { log_warn "$1"; ((VALIDATION_WARNINGS+=1)); }

log_info "=============================================="
log_info "STEP 19B - HOME ASSISTANT ZIGBEE VALIDATION"
log_info "=============================================="

[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in grep lsusb qm; do command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"; done

log_info "Checking Proxmox USB and VM passthrough configuration..."
[[ "$(lsusb -d "${ZIGBEE_USB_ID}" | wc -l)" -eq 1 ]] || record_error "Expected one host Zigbee USB device"
qm config "${HA_VM_ID}" | grep -qE "^usb[0-4]: host=${ZIGBEE_USB_ID}(,|$)" \
  || record_error "VM ${HA_VM_ID} does not contain the Zigbee USB passthrough"

if [[ "$(qm status "${HA_VM_ID}")" != "status: running" ]]; then
  record_error "Home Assistant VM ${HA_VM_ID} is not running"
elif ! qm agent "${HA_VM_ID}" ping >/dev/null 2>&1; then
  record_error "Home Assistant guest agent does not respond"
else
  log_info "Checking HAOS hardware inventory for the Sonoff serial identity..."
  hardware_info="$(qm guest exec "${HA_VM_ID}" -- bash -c \
    'ls -l /dev/serial/by-id 2>/dev/null; udevadm info --query=property --name=/dev/ttyUSB0 2>/dev/null' || true)"
  if grep -qi "${ZIGBEE_USB_SERIAL}" <<<"${hardware_info}" \
    && grep -qiE 'ttyUSB|Sonoff_Zigbee|Sonoff Zigbee' <<<"${hardware_info}"; then
    log_info "HAOS detects the Sonoff ZBDongle-P serial device"
  else
    record_error "HAOS hardware inventory does not contain the Sonoff ZBDongle-P"
  fi

  if [[ -n "${HA_TOKEN}" ]]; then
    ha_ip="$(qm agent "${HA_VM_ID}" network-get-interfaces 2>/dev/null \
      | awk '/"ip-address" :/ {ip=$3; gsub(/[",]/, "", ip)} /"ip-address-type" : "ipv4"/ {if (ip !~ /^(127|169\.254|172\.30)\./) {print ip; exit}}')"
    log_info "Checking that the Home Assistant ZHA config entry is loaded..."
    if [[ -n "${ha_ip}" ]] \
      && curl -fsS -H "Authorization: Bearer ${HA_TOKEN}" --max-time 15 \
        "http://${ha_ip}:${HA_HTTP_PORT}/api/config/config_entries/entry" \
        | python3 -c 'import json,sys; entries=json.load(sys.stdin); raise SystemExit(0 if any(x.get("domain")=="zha" and x.get("state")=="loaded" for x in entries) else 1)'; then
      log_info "Home Assistant reports the ZHA integration as loaded"
    else
      record_error "Home Assistant does not report a loaded ZHA config entry"
    fi
  else
    record_warn "HA_TOKEN is not configured; skipping ZHA config-entry validation"
  fi
fi

log_info "Checking that the Frigate Coral remains available..."
if pct exec "${DOCKER_CT_ID:-200}" -- docker exec frigate test -d /dev/bus/usb; then
  log_info "Frigate container still has USB access for Coral"
else
  record_error "Frigate container lost USB access"
fi

log_info "Validation warnings: ${VALIDATION_WARNINGS}"
log_info "Validation errors: ${VALIDATION_ERRORS}"
if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Zigbee USB validation failed"
  exit 1
fi
log_info "Zigbee USB passthrough validation completed successfully"
