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
GPU_STATS_SYSCTL_FILE="/etc/sysctl.d/99-frigate-gpu-stats.conf"
CORAL_PRESENT=0

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required commands..."
for cmd in pct lspci lsusb grep udevadm sysctl; do
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

ensure_file_line() {
  local file="$1"
  local line="$2"

  touch "${file}"
  if grep -Fxq "${line}" "${file}"; then
    log_info "Config already present: ${line}"
  else
    printf '%s\n' "${line}" >> "${file}"
    log_info "Added config: ${line}"
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

log_info "Configuring Intel GPU PMU access for Frigate metrics..."
if grep -q '^kernel\.perf_event_paranoid=' "${GPU_STATS_SYSCTL_FILE}" 2>/dev/null; then
  sed -i 's/^kernel\.perf_event_paranoid=.*/kernel.perf_event_paranoid=0/' "${GPU_STATS_SYSCTL_FILE}"
  log_info "Updated kernel.perf_event_paranoid to 0"
else
  ensure_file_line "${GPU_STATS_SYSCTL_FILE}" "kernel.perf_event_paranoid=0"
fi
sysctl -w kernel.perf_event_paranoid=0 >/dev/null

log_info "Configuring all hardware passthrough entries for CT ${CT_ID}..."
ensure_conf_line "lxc.cgroup2.devices.allow: c 226:* rwm"
ensure_conf_line "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"

if [[ "${CORAL_PRESENT}" -eq 1 ]]; then
  log_info "Configuring Coral USB passthrough for CT ${CT_ID}..."
  ensure_conf_line "lxc.cgroup2.devices.allow: c 189:* rwm"
  ensure_conf_line "lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir"
fi

log_info "Restarting CT ${CT_ID} once to apply all passthrough settings..."
if pct status "${CT_ID}" | grep -q "status: running"; then
  pct stop "${CT_ID}"
fi
pct start "${CT_ID}"
sleep 5

log_info "Validating /dev/dri inside CT ${CT_ID}..."
if pct exec "${CT_ID}" -- test -e /dev/dri/renderD128; then
  pct exec "${CT_ID}" -- ls -l /dev/dri
else
  log_error "/dev/dri/renderD128 is not visible inside CT ${CT_ID}"
  exit 1
fi

if [[ "${CORAL_PRESENT}" -eq 1 ]]; then
  log_info "Validating Coral USB access inside CT ${CT_ID}..."
  if ! pct exec "${CT_ID}" -- test -d /dev/bus/usb; then
    log_error "/dev/bus/usb is not visible inside CT ${CT_ID}"
    exit 1
  fi

  CORAL_USB_IDS="$(pct exec "${CT_ID}" -- lsusb 2>/dev/null | grep -E '1a6e:089a|18d1:9302' || true)"
  if [[ -z "${CORAL_USB_IDS}" ]]; then
    log_error "Coral USB identity is not visible inside CT ${CT_ID}"
    exit 1
  fi
  log_info "Coral USB identity visible inside CT: ${CORAL_USB_IDS}"

  if ! pct exec "${CT_ID}" -- find /dev/bus/usb -type c -perm -002 -print -quit | grep -q .; then
    log_error "No writable USB device node is visible inside CT ${CT_ID}"
    exit 1
  fi
fi

log_info "Hardware passthrough base validation completed successfully"
