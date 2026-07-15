#!/usr/bin/env bash
set -euo pipefail

RESTORE_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${RESTORE_SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

RESTORE_VMID="${BACKUP_RESTORE_TEST_VM_ID:-900}"
RESTORE_STORAGE="${BACKUP_RESTORE_STORAGE:-local-lvm}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/lib/vz/dump/homelab-backups}"
LOCK_FILE="/run/lock/proxmox-bootstrap-backup.lock"
MARKER="proxmox-bootstrap-restore-drill-$(date +%s)-$$"
CREATED=0

cleanup_restored_vm() {
  local description status
  [[ "${CREATED}" -eq 1 ]] || return 0
  [[ -f "/etc/pve/qemu-server/${RESTORE_VMID}.conf" ]] || return 0
  description="$(qm config "${RESTORE_VMID}" | sed -n 's/^description: //p')"
  status="$(qm status "${RESTORE_VMID}" 2>/dev/null || true)"
  if [[ "${description}" != "${MARKER}" || "${status}" != "status: stopped" ]]; then
    log_error "Refusing automatic cleanup: restore-drill ownership or stopped-state check failed"
    return 1
  fi
  log_info "Removing verified temporary VM ${RESTORE_VMID}"
  qm destroy "${RESTORE_VMID}"
  CREATED=0
}

on_exit() {
  local rc=$?
  if [[ "${CREATED}" -eq 1 ]]; then
    cleanup_restored_vm || rc=1
  fi
  exit "${rc}"
}
trap on_exit EXIT

[[ "${EUID}" -eq 0 ]] || die "Run as root"
[[ "${RESTORE_VMID}" =~ ^[1-9][0-9]*$ ]] || die "Restore VM ID must be a positive integer"
for cmd in flock find qm qmrestore pvesm zstd; do command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"; done

exec 9>"${LOCK_FILE}"
flock -n 9 || die "Another backup or restore operation is already running"

if qm status "${RESTORE_VMID}" >/dev/null 2>&1 || [[ -e "/etc/pve/qemu-server/${RESTORE_VMID}.conf" ]]; then
  die "VM ${RESTORE_VMID} already exists; refusing restore drill"
fi
while read -r storage _; do
  [[ -n "${storage}" && "${storage}" != "Name" ]] || continue
  if pvesm list "${storage}" --vmid "${RESTORE_VMID}" 2>/dev/null | awk 'NR > 1 {found=1} END {exit !found}'; then
    die "Storage ${storage} already contains volumes for VM ${RESTORE_VMID}"
  fi
done < <(pvesm status --enabled 1)
pvesm status --enabled 1 | awk -v storage="${RESTORE_STORAGE}" '$1 == storage && $3 == "active" {found=1} END {exit !found}' \
  || die "Restore storage is not active: ${RESTORE_STORAGE}"

RUN_DIR="$(find "${BACKUP_ROOT}" -mindepth 2 -maxdepth 2 -type f -name .validated -printf '%h\n' | sort | tail -1)"
[[ -n "${RUN_DIR}" ]] || die "No validated backup is available for restore testing"
bash "${RESTORE_SCRIPT_DIR}/step12-backup-validation.sh" "${RUN_DIR}"
mapfile -t archives < <(find "${RUN_DIR}" -maxdepth 1 -type f -name 'vzdump-qemu-100-*.vma.zst' -size +0c)
(( ${#archives[@]} == 1 )) || die "Expected exactly one Home Assistant vzdump archive"
ARCHIVE="${archives[0]}"
grep -Fq "$(basename "${ARCHIVE}")" "${RUN_DIR}/SHA256SUMS" || die "Home Assistant archive is absent from SHA256SUMS"
zstd -t --quiet "${ARCHIVE}"

log_info "Restoring Home Assistant archive to stopped temporary VM ${RESTORE_VMID}"
if ! qmrestore "${ARCHIVE}" "${RESTORE_VMID}" --storage "${RESTORE_STORAGE}" --unique 1 --start 0; then
  log_error "qmrestore failed; any partial VM ${RESTORE_VMID} resources require manual review"
  exit 1
fi
CREATED=1
qm set "${RESTORE_VMID}" --onboot 0 --description "${MARKER}"
[[ "$(qm status "${RESTORE_VMID}")" == "status: stopped" ]] || die "Restored VM is not stopped"

VM_CONFIG="$(qm config "${RESTORE_VMID}")"
grep -qx 'onboot: 0' <<<"${VM_CONFIG}" || die "Restored VM onboot is not disabled"
grep -qx "description: ${MARKER}" <<<"${VM_CONFIG}" || die "Restore-drill ownership marker is missing"
mapfile -t volumes < <(awk -F ': ' '/^(efidisk|scsi|sata|virtio|ide)[0-9]+:/ {split($2,a,","); if (a[1] !~ /^(none|cdrom)$/) print a[1]}' <<<"${VM_CONFIG}")
(( ${#volumes[@]} >= 2 )) || die "Expected restored main and EFI disks"
for volume in "${volumes[@]}"; do
  path="$(pvesm path "${volume}")"
  [[ -e "${path}" ]] || die "Restored volume path does not exist: ${volume}"
done

log_info "Stopped Home Assistant restore drill validated successfully"
cleanup_restored_vm
trap - EXIT
[[ ! -e "/etc/pve/qemu-server/${RESTORE_VMID}.conf" ]] || die "Temporary VM config remains after cleanup"
while read -r storage _; do
  [[ -n "${storage}" && "${storage}" != "Name" ]] || continue
  if pvesm list "${storage}" --vmid "${RESTORE_VMID}" 2>/dev/null | awk 'NR > 1 {found=1} END {exit !found}'; then
    die "Temporary VM volumes remain on storage ${storage}"
  fi
done < <(pvesm status --enabled 1)
log_info "Home Assistant restore drill completed and temporary VM removed"
