#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

MODE=""
CONFIRM_RESTART=0
while (($#)); do
  case "$1" in
    --dry-run|--apply)
      [[ -z "$MODE" ]] || { printf 'Choose only one of --dry-run or --apply\n' >&2; exit 2; }
      MODE="${1#--}"
      shift
      ;;
    --confirm-restart)
      (( CONFIRM_RESTART == 0 )) || { printf '%s\n' '--confirm-restart may only be provided once' >&2; exit 2; }
      CONFIRM_RESTART=1
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 --dry-run
       $0 --apply [--confirm-restart]

--dry-run checks hardware and prints planned changes without writing files,
changing sysctls, reloading udev, or starting/stopping CT ${DOCKER_CT_ID:-200}.
--apply writes host/LXC configuration. It leaves the CT running as-is unless
--confirm-restart is also supplied; a stopped CT remains stopped.
EOF
      exit 0
      ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -n "$MODE" ]] || { printf '%s\n' 'Choose --dry-run or --apply; use --help for details.' >&2; exit 2; }
if (( CONFIRM_RESTART == 1 )) && [[ "$MODE" != apply ]]; then
  printf '%s\n' '--confirm-restart requires --apply' >&2
  exit 2
fi
if [[ "$MODE" == dry-run ]]; then export LOG_FILE=/dev/null; fi

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

log_info "======================================"
log_info "STEP 03C - HARDWARE PASSTHROUGH"
log_info "======================================"

CT_ID="${DOCKER_CT_ID:-200}"
LXC_CONFIG_DIR="${PROXMOX_LXC_CONFIG_DIR:-/etc/pve/lxc}"
UDEV_RULE_DIR="${FRIGATE_UDEV_RULE_DIR:-/etc/udev/rules.d}"
SYSCTL_CONFIG_DIR="${FRIGATE_SYSCTL_CONFIG_DIR:-/etc/sysctl.d}"
DRI_DIR="${FRIGATE_DRI_DIR:-/dev/dri}"
CT_CONF="${LXC_CONFIG_DIR}/${CT_ID}.conf"
GPU_STATS_SYSCTL_FILE="${SYSCTL_CONFIG_DIR}/99-frigate-gpu-stats.conf"
CORAL_PRESENT=0
CT_CONFIG_CHANGED=0
UDEV_RULES_CHANGED=0
SYSCTL_CONFIG_CHANGED=0

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required commands..."
for cmd in pct lspci lsusb grep udevadm sysctl sed sleep; do
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

CT_STATUS="$(pct status "${CT_ID}")" || {
  log_error "Could not determine CT ${CT_ID} state; refusing to change host or CT configuration"
  exit 1
}
case "$CT_STATUS" in
  *"status: running"*) CT_WAS_RUNNING=1 ;;
  *"status: stopped"*) CT_WAS_RUNNING=0 ;;
  *) log_error "Unrecognized CT ${CT_ID} status: ${CT_STATUS}"; exit 1 ;;
esac

ensure_conf_line() {
  local line="$1"

  if grep -Fxq "${line}" "${CT_CONF}"; then
    log_info "Config already present: ${line}"
  elif [[ "$MODE" == dry-run ]]; then
    log_info "[DRY-RUN] Would add CT config: ${line}"
  else
    log_info "Adding config: ${line}"
    printf '%s\n' "${line}" >> "${CT_CONF}"
    CT_CONFIG_CHANGED=1
  fi
}

ensure_udev_rule() {
  local rule_file="$1"
  local rule="$2"

  if grep -Fxq "${rule}" "${rule_file}" 2>/dev/null; then
    log_info "udev rule already present: ${rule}"
  elif [[ "$MODE" == dry-run ]]; then
    log_info "[DRY-RUN] Would add udev rule to ${rule_file}: ${rule}"
  else
    mkdir -p "$(dirname -- "${rule_file}")"
    printf '%s\n' "${rule}" >> "${rule_file}"
    log_info "Added udev rule: ${rule}"
    UDEV_RULES_CHANGED=1
  fi
}

ensure_file_line() {
  local file="$1"
  local line="$2"

  if grep -Fxq "${line}" "${file}"; then
    log_info "Config already present: ${line}"
  elif [[ "$MODE" == dry-run ]]; then
    log_info "[DRY-RUN] Would add sysctl setting to ${file}: ${line}"
  else
    mkdir -p "$(dirname -- "${file}")"
    printf '%s\n' "${line}" >> "${file}"
    log_info "Added config: ${line}"
    SYSCTL_CONFIG_CHANGED=1
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
if [[ ! -d "$DRI_DIR" ]]; then
  log_error "/dev/dri does not exist on host"
  exit 1
fi
ls -l "$DRI_DIR"

log_info "Checking Coral USB TPU on host..."
if lsusb | grep -qiE 'google|coral|global unichip|18d1:9302|1a6e:089a'; then
  CORAL_PRESENT=1
  log_info "Coral USB TPU detected"
else
  log_warn "Coral USB TPU not detected by lsusb"
fi

if [[ "${CORAL_PRESENT}" -eq 1 ]]; then
  log_info "Configuring writable udev permissions for both Coral USB identities..."
  CORAL_UDEV_RULE_FILE="${UDEV_RULE_DIR}/99-coral-edgetpu.rules"
  ensure_udev_rule "${CORAL_UDEV_RULE_FILE}" 'SUBSYSTEM=="usb", ATTR{idVendor}=="1a6e", ATTR{idProduct}=="089a", MODE="0666"'
  ensure_udev_rule "${CORAL_UDEV_RULE_FILE}" 'SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="9302", MODE="0666"'

fi

log_info "Configuring writable udev permissions for Intel GPU device nodes..."
GPU_UDEV_RULE_FILE="${UDEV_RULE_DIR}/99-frigate-gpu.rules"
ensure_udev_rule "${GPU_UDEV_RULE_FILE}" 'SUBSYSTEM=="drm", KERNEL=="card0", MODE="0666"'
ensure_udev_rule "${GPU_UDEV_RULE_FILE}" 'SUBSYSTEM=="drm", KERNEL=="renderD128", MODE="0666"'

log_info "Configuring Intel GPU PMU access for Frigate metrics..."
if grep -q '^kernel\.perf_event_paranoid=0$' "${GPU_STATS_SYSCTL_FILE}" 2>/dev/null; then
  log_info "GPU PMU setting already present"
elif grep -q '^kernel\.perf_event_paranoid=' "${GPU_STATS_SYSCTL_FILE}" 2>/dev/null; then
  if [[ "$MODE" == dry-run ]]; then
    log_info "[DRY-RUN] Would set kernel.perf_event_paranoid=0 in ${GPU_STATS_SYSCTL_FILE}"
  else
    sed -i 's/^kernel\.perf_event_paranoid=.*/kernel.perf_event_paranoid=0/' "${GPU_STATS_SYSCTL_FILE}"
    SYSCTL_CONFIG_CHANGED=1
    log_info "Updated kernel.perf_event_paranoid to 0"
  fi
else
  ensure_file_line "${GPU_STATS_SYSCTL_FILE}" "kernel.perf_event_paranoid=0"
fi

log_info "Configuring all hardware passthrough entries for CT ${CT_ID}..."
ensure_conf_line "lxc.cgroup2.devices.allow: c 226:* rwm"
ensure_conf_line "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"

if [[ "${CORAL_PRESENT}" -eq 1 ]]; then
  log_info "Configuring Coral USB passthrough for CT ${CT_ID}..."
  ensure_conf_line "lxc.cgroup2.devices.allow: c 189:* rwm"
  ensure_conf_line "lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir"
fi

if [[ "$MODE" == dry-run ]]; then
  log_info "[DRY-RUN] No host or CT changes were made."
  exit 0
fi

if (( UDEV_RULES_CHANGED )); then
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=usb
  udevadm trigger --subsystem-match=drm
fi
if (( SYSCTL_CONFIG_CHANGED )) || [[ "$(sysctl -n kernel.perf_event_paranoid)" != 0 ]]; then
  sysctl -w kernel.perf_event_paranoid=0 >/dev/null
fi

if (( CT_WAS_RUNNING )); then
  if (( CONFIRM_RESTART )); then
    log_warn "Restarting CT ${CT_ID} as explicitly requested"
    if ! pct stop "${CT_ID}"; then
      log_error "Could not confirm CT ${CT_ID} stopped; inspect with: pct status ${CT_ID}"
      exit 1
    fi
    if ! pct start "${CT_ID}"; then
      log_error "CT ${CT_ID} did not start after the requested restart"
      log_error "Recovery command: pct start ${CT_ID}"
      exit 1
    fi
    sleep 5
  elif (( CT_CONFIG_CHANGED )); then
    log_warn "CT ${CT_ID} remains running; LXC config changes need a planned restart to take effect"
    log_info "Rerun with --apply --confirm-restart during a suitable outage window to apply them"
  fi
else
  log_info "CT ${CT_ID} was stopped and remains stopped"
fi

if (( ! CT_WAS_RUNNING )); then
  log_info "Configuration applied; runtime validation skipped because CT ${CT_ID} is stopped"
  exit 0
fi

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
