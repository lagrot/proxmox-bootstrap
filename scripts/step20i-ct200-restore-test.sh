#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

SOURCE_CT_ID="${DOCKER_CT_ID:-200}"
RESTORE_CT_ID="${SECURITY_UPDATE_RESTORE_TEST_CT_ID:-920}"
RESTORE_STORAGE="${SECURITY_UPDATE_RESTORE_STORAGE:-local-lvm}"
BACKUP_ROOT="${SECURITY_UPDATE_BACKUP_ROOT:-/var/lib/vz/dump/security-update-backups}"
TEST_DIR="$(dirname "${BACKUP_ROOT}")/.pbtest-$(date +%Y%m%d-%H%M%S)-ct200"
MARKER="proxmox-bootstrap-ct200-restore-test-$(date +%s)-$$"
ARCHIVE=""
RESTORED=0
MOUNTED=0
SOURCE_MUST_RUN=0

wait_running() {
  local attempt consecutive=0
  for ((attempt=1; attempt<=60; attempt++)); do
    if pct status "${SOURCE_CT_ID}" 2>/dev/null | grep -q 'status: running'; then
      consecutive=$((consecutive + 1))
      (( consecutive >= 3 )) && return 0
    else
      consecutive=0
    fi
    sleep 2
  done
  return 1
}

remove_restored_ct() {
  local description status
  [[ "${RESTORED}" -eq 1 ]] || return 0
  if (( MOUNTED == 1 )); then
    pct unmount "${RESTORE_CT_ID}" >/dev/null
    MOUNTED=0
  fi
  [[ -f "/etc/pve/lxc/${RESTORE_CT_ID}.conf" ]] || return 0
  description="$(pct config "${RESTORE_CT_ID}" | sed -n 's/^description: //p')"
  status="$(pct status "${RESTORE_CT_ID}" 2>/dev/null || true)"
  if [[ "${description}" != "${MARKER}" \
      && "${description}" != "${MARKER}%0A" ]] \
      || [[ "${status}" != "status: stopped" ]]; then
    log_error "Refusing cleanup: temporary CT ownership or stopped-state check failed"
    return 1
  fi
  log_info "Removing verified temporary CT ${RESTORE_CT_ID}"
  pct destroy "${RESTORE_CT_ID}" --purge 1
  RESTORED=0
}

on_exit() {
  local rc=$?
  set +e
  if (( SOURCE_MUST_RUN == 1 )); then
    if ! pct status "${SOURCE_CT_ID}" 2>/dev/null | grep -q 'status: running'; then
      log_warn "Restarting source CT ${SOURCE_CT_ID}"
      pct start "${SOURCE_CT_ID}" >/dev/null 2>&1
    fi
    wait_running || {
      log_error "Source CT ${SOURCE_CT_ID} did not return to a stable running state"
      rc=1
    }
  fi
  remove_restored_ct || rc=1
  [[ -d "${TEST_DIR}" ]] && rm -rf -- "${TEST_DIR}"
  exit "${rc}"
}
trap on_exit EXIT

[[ "${EUID}" -eq 0 ]] || die "Run as root"
[[ "${RESTORE_CT_ID}" =~ ^[1-9][0-9]*$ ]] \
  || die "Restore-test CT ID must be a positive integer"
for cmd in awk basename df find flock grep pct pvesm qm sha256sum tar vzdump zstd; do
  command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"
done

exec 9>/run/lock/proxmox-bootstrap-security-update.lock
flock -n 9 || die "Another security-update operation is running"
exec 8>/run/lock/proxmox-bootstrap-backup.lock
flock -n 8 || die "A backup or restore operation is running"

pct status "${SOURCE_CT_ID}" | grep -q 'status: running' \
  || die "Source CT ${SOURCE_CT_ID} is not running"
if pct status "${RESTORE_CT_ID}" >/dev/null 2>&1 \
    || qm status "${RESTORE_CT_ID}" >/dev/null 2>&1 \
    || [[ -e "/etc/pve/lxc/${RESTORE_CT_ID}.conf" \
      || -e "/etc/pve/qemu-server/${RESTORE_CT_ID}.conf" ]]; then
  die "Temporary guest ID ${RESTORE_CT_ID} is already in use"
fi
while read -r storage _; do
  [[ -n "${storage}" && "${storage}" != "Name" ]] || continue
  if pvesm list "${storage}" --vmid "${RESTORE_CT_ID}" 2>/dev/null \
      | awk 'NR > 1 {found=1} END {exit !found}'; then
    die "Storage ${storage} already contains volumes for CT ${RESTORE_CT_ID}"
  fi
done < <(pvesm status --enabled 1)
pvesm status --enabled 1 \
  | awk -v storage="${RESTORE_STORAGE}" \
      '$1 == storage && $3 == "active" {found=1} END {exit !found}' \
  || die "Restore storage is not active: ${RESTORE_STORAGE}"

mkdir -p -m 0755 "${TEST_DIR}"
log_warn "Creating stopped CT ${SOURCE_CT_ID} restore-test backup"
SOURCE_MUST_RUN=1
(
  umask 0022
  vzdump "${SOURCE_CT_ID}" --mode stop --compress zstd \
    --dumpdir "${TEST_DIR}"
)
wait_running || die "Source CT ${SOURCE_CT_ID} did not return after backup"
SOURCE_MUST_RUN=0

mapfile -t archives < <(
  find "${TEST_DIR}" -maxdepth 1 -type f \
    -name "vzdump-lxc-${SOURCE_CT_ID}-*.tar.zst" -size +0c
)
(( ${#archives[@]} == 1 )) || die "Expected exactly one CT backup archive"
ARCHIVE="${archives[0]}"
chmod 0600 "${ARCHIVE}"
(
  cd "${TEST_DIR}"
  sha256sum -- "$(basename "${ARCHIVE}")" >SHA256SUMS
  sha256sum -c SHA256SUMS
)
zstd -t --quiet "${ARCHIVE}"
archive_config="$(tar --zstd -xOf "${ARCHIVE}" ./etc/vzdump/pct.conf)"
current_mp0="$(pct config "${SOURCE_CT_ID}" | sed -n 's/^mp0: //p')"
archived_mp0="$(sed -n 's/^mp0: //p' <<<"${archive_config}")"
[[ -n "${current_mp0}" && "${archived_mp0}" == "${current_mp0}" ]] \
  || die "Backup does not preserve the Frigate media bind-mount configuration"

log_info "Restoring archive to stopped temporary CT ${RESTORE_CT_ID}"
if ! (
  umask 0022
  pct restore "${RESTORE_CT_ID}" "${ARCHIVE}" \
      --storage "${RESTORE_STORAGE}" --unique 1 --start 0 --onboot 0 \
      --description "${MARKER}"
); then
  log_error "Restore failed; inspect any partial CT ${RESTORE_CT_ID} resources"
  exit 1
fi
RESTORED=1
[[ "$(pct status "${RESTORE_CT_ID}")" == "status: stopped" ]] \
  || die "Temporary restore CT is not stopped"
restored_config="$(pct config "${RESTORE_CT_ID}")"
restored_description="$(
  sed -n 's/^description: //p' <<<"${restored_config}"
)"
[[ "${restored_description}" == "${MARKER}" \
    || "${restored_description}" == "${MARKER}%0A" ]] \
  || die "Temporary restore ownership marker is missing"
grep -qx "onboot: 0" <<<"${restored_config}" \
  || die "Temporary restore could start automatically"
grep -qx "mp0: ${current_mp0}" <<<"${restored_config}" \
  || die "Temporary restore does not preserve the media bind mount"

log_info "Inspecting restored CT 200 root filesystem without starting it"
pct mount "${RESTORE_CT_ID}" >/dev/null
MOUNTED=1
RESTORED_ROOT="/var/lib/lxc/${RESTORE_CT_ID}/rootfs"
[[ -f "${RESTORED_ROOT}/opt/frigate/docker-compose.yml" ]] \
  || die "Restored Frigate Compose file is missing"
[[ -f "${RESTORED_ROOT}/opt/frigate/config/config.yml" ]] \
  || die "Restored Frigate configuration is missing"
pct unmount "${RESTORE_CT_ID}" >/dev/null
MOUNTED=0

log_info "Stopped CT 200 full-backup restore drill passed"
remove_restored_ct
rm -rf -- "${TEST_DIR}"
trap - EXIT
[[ ! -e "/etc/pve/lxc/${RESTORE_CT_ID}.conf" ]] \
  || die "Temporary CT configuration remains after cleanup"
while read -r storage _; do
  [[ -n "${storage}" && "${storage}" != "Name" ]] || continue
  if pvesm list "${storage}" --vmid "${RESTORE_CT_ID}" 2>/dev/null \
      | awk 'NR > 1 {found=1} END {exit !found}'; then
    die "Temporary CT volumes remain on storage ${storage}"
  fi
done < <(pvesm status --enabled 1)
log_info "Temporary CT and restore-test backup were removed"
