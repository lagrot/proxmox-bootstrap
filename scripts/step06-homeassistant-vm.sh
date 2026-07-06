#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      cat <<'HELP'
Usage: step06-homeassistant-vm.sh [--dry-run]

Creates Home Assistant OS VM 100 on Proxmox.

Environment/config defaults:
  HA_VM_ID              default: 100
  HA_VM_NAME            default: homeassistant
  HA_VM_MEMORY_MB       default: 4096
  HA_VM_CORES           default: 2
  HA_VM_STORAGE         default: local-lvm
  HA_VM_BRIDGE          default: vmbr0
  HAOS_VERSION          default: 18.0
HELP
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

log_info "======================================"
log_info "STEP 06 - HOME ASSISTANT OS VM"
log_info "======================================"

HA_VM_ID="${HA_VM_ID:-100}"
HA_VM_NAME="${HA_VM_NAME:-homeassistant}"
HA_VM_MEMORY_MB="${HA_VM_MEMORY_MB:-4096}"
HA_VM_CORES="${HA_VM_CORES:-2}"
HA_VM_STORAGE="${HA_VM_STORAGE:-local-lvm}"
HA_VM_BRIDGE="${HA_VM_BRIDGE:-vmbr0}"
HA_VM_IMAGE_DIR="${HA_VM_IMAGE_DIR:-/var/lib/vz/template/iso}"

# Pin the image for repeatable builds.
# Update this later when we intentionally upgrade the bootstrap image.
HAOS_VERSION="${HAOS_VERSION:-18.0}"
HAOS_IMAGE_BASENAME="${HAOS_IMAGE_BASENAME:-haos_ova-${HAOS_VERSION}.qcow2.xz}"
HAOS_IMAGE_URL="${HAOS_IMAGE_URL:-https://github.com/home-assistant/operating-system/releases/download/${HAOS_VERSION}/${HAOS_IMAGE_BASENAME}}"

HAOS_XZ_PATH="${HA_VM_IMAGE_DIR}/${HAOS_IMAGE_BASENAME}"
HAOS_QCOW2_PATH="${HAOS_XZ_PATH%.xz}"

run_host() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[DRY-RUN] $*"
  else
    "$@"
  fi
}

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required commands..."
for cmd in qm pvesm wget xz awk grep ip; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Required command not found: ${cmd}"
    exit 1
  fi
done

log_info "Checking Proxmox bridge ${HA_VM_BRIDGE}..."
if ! ip link show "${HA_VM_BRIDGE}" >/dev/null 2>&1; then
  log_error "Proxmox bridge not found: ${HA_VM_BRIDGE}"
  exit 1
fi

log_info "Checking Proxmox storage ${HA_VM_STORAGE}..."
if ! pvesm status | awk '{print $1}' | grep -qx "${HA_VM_STORAGE}"; then
  log_error "Proxmox storage not found: ${HA_VM_STORAGE}"
  exit 1
fi

log_info "Checking whether VM ${HA_VM_ID} already exists..."
if qm config "${HA_VM_ID}" >/dev/null 2>&1; then
  log_error "VM ${HA_VM_ID} already exists. Refusing to modify existing VM."
  log_error "Delete it manually first if you want to recreate it:"
  log_error "qm destroy ${HA_VM_ID} --purge"
  exit 1
fi

log_info "Creating image directory ${HA_VM_IMAGE_DIR}..."
run_host mkdir -p "${HA_VM_IMAGE_DIR}"

log_info "Preparing Home Assistant OS image..."
log_info "HAOS version: ${HAOS_VERSION}"
log_info "Image URL: ${HAOS_IMAGE_URL}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] wget -O ${HAOS_XZ_PATH} ${HAOS_IMAGE_URL}"
  log_info "[DRY-RUN] xz -dk ${HAOS_XZ_PATH}"
else
  if [[ ! -f "${HAOS_XZ_PATH}" ]]; then
    wget -O "${HAOS_XZ_PATH}" "${HAOS_IMAGE_URL}"
  else
    log_info "Compressed image already exists: ${HAOS_XZ_PATH}"
  fi

  if [[ ! -f "${HAOS_QCOW2_PATH}" ]]; then
    xz -dk "${HAOS_XZ_PATH}"
  else
    log_info "Decompressed image already exists: ${HAOS_QCOW2_PATH}"
  fi
fi

log_info "Creating VM ${HA_VM_ID} (${HA_VM_NAME})..."
run_host qm create "${HA_VM_ID}" \
  --name "${HA_VM_NAME}" \
  --memory "${HA_VM_MEMORY_MB}" \
  --cores "${HA_VM_CORES}" \
  --cpu host \
  --machine q35 \
  --bios ovmf \
  --ostype l26 \
  --net0 "virtio,bridge=${HA_VM_BRIDGE}" \
  --agent enabled=1 \
  --tablet 0 \
  --onboot 1

log_info "Adding EFI disk..."
run_host qm set "${HA_VM_ID}" \
  --efidisk0 "${HA_VM_STORAGE}:0,efitype=4m,pre-enrolled-keys=0"

log_info "Importing Home Assistant OS disk..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] qm importdisk ${HA_VM_ID} ${HAOS_QCOW2_PATH} ${HA_VM_STORAGE}"
else
  qm importdisk "${HA_VM_ID}" "${HAOS_QCOW2_PATH}" "${HA_VM_STORAGE}"
fi

log_info "Detecting imported disk volume..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  IMPORTED_DISK="${HA_VM_STORAGE}:vm-${HA_VM_ID}-disk-1"
  log_info "[DRY-RUN] imported disk assumed: ${IMPORTED_DISK}"
else
  IMPORTED_DISK="$(
    qm config "${HA_VM_ID}" \
      | awk -F': ' '/unused[0-9]+:/ {print $2; exit}'
  )"

  if [[ -z "${IMPORTED_DISK}" ]]; then
    log_error "Could not find imported disk as unused disk in VM config"
    qm config "${HA_VM_ID}"
    exit 1
  fi

  log_info "Imported disk found: ${IMPORTED_DISK}"
fi

log_info "Attaching imported disk as scsi0..."
run_host qm set "${HA_VM_ID}" \
  --scsihw virtio-scsi-single \
  --scsi0 "${IMPORTED_DISK},discard=on,ssd=1"

log_info "Setting boot order..."
run_host qm set "${HA_VM_ID}" \
  --boot order=scsi0

log_info "Adding serial console..."
run_host qm set "${HA_VM_ID}" \
  --serial0 socket \
  --vga serial0

log_info "Starting VM ${HA_VM_ID}..."
run_host qm start "${HA_VM_ID}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "Dry-run completed successfully"
  log_info "No VM was created or modified because --dry-run was used"
  exit 0
fi

log_info "Waiting briefly for VM startup..."
sleep 10

log_info "VM status:"
qm status "${HA_VM_ID}"

log_info "Home Assistant OS VM deployment completed successfully"
log_info "VM ID: ${HA_VM_ID}"
log_info "VM name: ${HA_VM_NAME}"
log_info "Open the Proxmox console and wait for Home Assistant first boot to complete."
log_info "Home Assistant should later be reachable at: http://homeassistant.local:8123"
