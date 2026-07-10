#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

log_info "======================================"
log_info "STEP 03C - HARDWARE PASSTHROUGH"
log_info "======================================"

CT_ID="${DOCKER_CT_ID:-200}"
CT_CONF="/etc/pve/lxc/${CT_ID}.conf"
CORAL_PRESENT=0

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required commands..."
for cmd in pct lspci lsusb grep udevadm; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Required command not found: ${cmd}"
    exit 1
  fi
done

log_info "Checking whether CT ${CT_ID} exists..."
if ! pct config "${CT_ID}" >/dev/null 2>&1; then
  log_error "CT ${CT_ID} does not exist"
  exit 1
fi

if [[ ! -f "${CT_CONF}" ]]; then
  log_error "CT config file not found: ${CT_CONF}"
  exit 1
fi

ensure_conf_line() {
  local line="$1"

  if grep -Fxq "${line}" "${CT_CONF}"; then
    log_info "Config already present: ${line}"
  else
    log_info "Adding config: ${line}"
    echo "${line}" >> "${CT_CONF}"
  fi
}

ensure_udev_rule() {
  local rule_file="$1"
  local rule="$2"

  if grep -Fxq "${rule}" "${rule_file}" 2>/dev/null; then
    log_info "udev rule already present: ${rule}"
  else
    printf '%s\n' "${rule}" >> "${rule_file}"
    log_info "Added udev rule: ${rule}"
  fi
}

log_info "Checking Intel iGPU on host..."
if lspci | grep -Ei 'vga|display|3d' | grep -qi 'intel'; then
  log_info "Intel GPU detected"
else
  log_error "No Intel GPU detected with lspci"
  log_info "lspci graphics-related output:"
  lspci | grep -Ei 'vga|display|3d' || true
  exit 1
fi

log_info "Checking /dev/dri on host..."
if [[ ! -d /dev/dri ]]; then
  log_error "/dev/dri does not exist on host"
  exit 1
fi
ls -l /dev/dri

log_info "Checking Coral USB TPU on host..."
if lsusb | grep -qiE 'google|coral|global unichip|18d1:9302|1a6e:089a'; then
  CORAL_PRESENT=1
  log_info "Coral USB TPU detected"
else
  log_warn "Coral USB TPU not detected by lsusb"
fi

if [[ "${CORAL_PRESENT}" -eq 1 ]]; then
  log_info "Configuring writable udev permissions for both Coral USB identities..."
  CORAL_UDEV_RULE_FILE="/etc/udev/rules.d/99-coral-edgetpu.rules"
  ensure_udev_rule "${CORAL_UDEV_RULE_FILE}" 'SUBSYSTEM=="usb", ATTR{idVendor}=="1a6e", ATTR{idProduct}=="089a", MODE="0666"'
  ensure_udev_rule "${CORAL_UDEV_RULE_FILE}" 'SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="9302", MODE="0666"'

  udevadm control --reload-rules
  udevadm trigger --subsystem-match=usb
fi

log_info "Configuring writable udev permissions for Intel GPU device nodes..."
GPU_UDEV_RULE_FILE="/etc/udev/rules.d/99-frigate-gpu.rules"
ensure_udev_rule "${GPU_UDEV_RULE_FILE}" 'SUBSYSTEM=="drm", KERNEL=="card0", MODE="0666"'
ensure_udev_rule "${GPU_UDEV_RULE_FILE}" 'SUBSYSTEM=="drm", KERNEL=="renderD128", MODE="0666"'
udevadm control --reload-rules
udevadm trigger --subsystem-match=drm

log_info "Configuring iGPU passthrough for CT ${CT_ID}..."
ensure_conf_line "lxc.cgroup2.devices.allow: c 226:* rwm"
ensure_conf_line "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"

log_info "Restarting CT ${CT_ID} to apply passthrough config..."
if pct status "${CT_ID}" | grep -q "status: running"; then
  pct stop "${CT_ID}"
fi
pct start "${CT_ID}"
sleep 5

log_info "Validating /dev/dri inside CT ${CT_ID}..."
if pct exec "${CT_ID}" -- test -d /dev/dri; then
  pct exec "${CT_ID}" -- ls -l /dev/dri
else
  log_error "/dev/dri is not visible inside CT ${CT_ID}"
  log_info "Relevant CT config:"
  grep -E '^(lxc\.cgroup2\.devices\.allow|lxc\.mount\.entry):' "${CT_CONF}" || true
  exit 1
fi

if [[ "${CORAL_PRESENT}" -eq 1 ]]; then
  log_info "Configuring Coral USB passthrough for CT ${CT_ID}..."
  ensure_conf_line "lxc.cgroup2.devices.allow: c 189:* rwm"
  ensure_conf_line "lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir"

  log_info "Restarting CT ${CT_ID} to apply Coral passthrough config..."
  if pct status "${CT_ID}" | grep -q "status: running"; then
    pct stop "${CT_ID}"
  fi
  pct start "${CT_ID}"
  sleep 5

  log_info "Validating /dev/bus/usb inside CT ${CT_ID}..."
  if pct exec "${CT_ID}" -- test -d /dev/bus/usb; then
    log_info "/dev/bus/usb is visible inside CT ${CT_ID}"
    pct exec "${CT_ID}" -- find /dev/bus/usb -type c | head -20
  else
    log_error "/dev/bus/usb is not visible inside CT ${CT_ID}"
    log_info "Relevant CT config:"
    grep -E '^(lxc\.cgroup2\.devices\.allow|lxc\.mount\.entry):' "${CT_CONF}" || true
    exit 1
  fi
fi

log_info "Hardware passthrough base validation completed successfully"
