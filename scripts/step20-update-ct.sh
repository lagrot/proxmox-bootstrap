#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

STEP20_UPDATE_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${STEP20_UPDATE_SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

TARGET=""
MODE=""
CT_ID=""
SNAPSHOT=""
SNAPSHOT_CREATED=0
BACKUP_DIR=""
BACKUP_ARCHIVE=""
BACKUP_CREATED=0
BACKUP_STAGING_DIR=""
NEEDS_START=0
APT_DAILY_TIMER_PAUSED=0
STAGE="preflight"
STATE_DIR="${SECURITY_UPDATE_STATE_DIR:-/var/lib/proxmox-bootstrap/security-updates}"
STATE_FILE=""
SNAPSHOT_PREFIX="pbsec"
BACKUP_ROOT="${SECURITY_UPDATE_BACKUP_ROOT:-/var/lib/vz/dump/security-update-backups}"
MIN_SNAPSHOT_AGE_SECONDS="${SECURITY_UPDATE_SNAPSHOT_MIN_AGE_SECONDS:-86400}"
MAX_STORAGE_USED_PERCENT="${SECURITY_UPDATE_MAX_STORAGE_USED_PERCENT:-80}"

usage() {
  cat <<EOF
Usage: $0 TARGET (--dry-run | --confirm | --cleanup)

Targets: ct200, ct210, ct220

  --dry-run  Refresh metadata and verify the security plan without installing.
  --confirm  Discover updates, create rollback protection, install and validate.
  --cleanup  After 24 hours, validate again and remove rollback protection.

CT 200 uses a stopped full-rootfs backup because its media bind mount prevents
LXC snapshots. CT 210 and CT 220 use Proxmox snapshots.
EOF
}

write_state() {
  local result="$1" stage="$2" temp
  mkdir -p -m 0700 "${STATE_DIR}"
  temp="${STATE_FILE}.tmp"
  printf 'target=%s\nct_id=%s\nprotection_type=%s\nsnapshot=%s\nbackup_dir=%s\nbackup_archive=%s\ncreated_epoch=%s\ncreated_at=%s\nresult=%s\nstage=%s\n' \
    "${TARGET}" "${CT_ID}" "${PROTECTION_TYPE}" "${SNAPSHOT}" \
    "${BACKUP_DIR}" "${BACKUP_ARCHIVE}" "${PROTECTION_CREATED_EPOCH}" \
    "${PROTECTION_CREATED_AT}" "${result}" "${stage}" >"${temp}"
  chmod 0600 "${temp}"
  mv -f "${temp}" "${STATE_FILE}"
}

state_value() {
  local key="$1"
  awk -F= -v key="${key}" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "${STATE_FILE}"
}

snapshot_exists() {
  local name="$1"
  pct listsnapshot "${CT_ID}" | awk '$2 != "current" {print $2}' | grep -Fxq "${name}"
}

wait_running() {
  local attempt consecutive=0
  for ((attempt=1; attempt<=60; attempt++)); do
    if pct status "${CT_ID}" 2>/dev/null | grep -q 'status: running'; then
      consecutive=$((consecutive + 1))
      (( consecutive >= 3 )) && return 0
    else
      consecutive=0
    fi
    sleep 2
  done
  return 1
}

on_exit() {
  local rc=$?
  if (( NEEDS_START == 1 )); then
    set +e
    log_warn "Attempting to restart CT ${CT_ID}"
    if pct status "${CT_ID}" 2>/dev/null | grep -q 'status: running' \
        && wait_running; then
      NEEDS_START=0
    elif pct start "${CT_ID}" >/dev/null 2>&1 && wait_running; then
      NEEDS_START=0
    else
      log_error "CT ${CT_ID} did not return to a stable running state"
      (( rc == 0 )) && rc=1
    fi
  fi
  if (( rc != 0 && SNAPSHOT_CREATED == 1 )); then
    set +e
    write_state failed "${STAGE}"
    log_error "CT ${CT_ID} update stopped during ${STAGE}"
    log_warn "Snapshot retained: ${SNAPSHOT}"
    log_warn "Do not roll back automatically. Inspect first, then use:"
    log_warn "  pct stop ${CT_ID}"
    log_warn "  pct rollback ${CT_ID} ${SNAPSHOT}"
    log_warn "  pct start ${CT_ID}"
    log_warn "  bash scripts/step20c-post-update-validation.sh ${TARGET}"
  fi
  if (( rc != 0 && BACKUP_CREATED == 1 )); then
    set +e
    write_state failed "${STAGE}"
    log_error "CT ${CT_ID} update stopped during ${STAGE}"
    log_warn "Full-rootfs rollback backup retained: ${BACKUP_ARCHIVE}"
    log_warn "Do not restore automatically. Inspect first, then use:"
    log_warn "  pct stop ${CT_ID}"
    log_warn "  pct restore ${CT_ID} ${BACKUP_ARCHIVE} --force 1 --storage local-lvm"
    log_warn "  pct start ${CT_ID}"
    log_warn "  bash scripts/step20c-post-update-validation.sh ${TARGET}"
    log_warn "The /mnt/frigate media bind mount is not changed by this restore."
  elif (( rc != 0 )) && [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" \
      && ! -f "${BACKUP_DIR}/.validated" ]]; then
    set +e
    log_warn "Removing incomplete CT ${CT_ID} rollback backup"
    rm -rf -- "${BACKUP_DIR}"
  fi
  if [[ -n "${BACKUP_STAGING_DIR}" && -d "${BACKUP_STAGING_DIR}" ]]; then
    set +e
    rm -rf -- "${BACKUP_STAGING_DIR}"
  fi
  if (( APT_DAILY_TIMER_PAUSED == 1 )); then
    set +e
    if pct exec "${CT_ID}" -- systemctl start apt-daily.timer >/dev/null 2>&1; then
      log_info "Restored the CT ${CT_ID} package-metadata timer"
    else
      log_error "Could not restore CT ${CT_ID} apt-daily.timer"
      (( rc == 0 )) && rc=1
    fi
  fi
  exit "${rc}"
}
trap on_exit EXIT

run_baseline() {
  log_info "Validating current ${TARGET} functionality"
  bash "${STEP20_UPDATE_SCRIPT_DIR}/step20c-post-update-validation.sh" "${TARGET}"
}

security_plan() {
  local simulation package_line
  simulation="$(pct exec "${CT_ID}" -- unattended-upgrade --dry-run --verbose 2>&1)" \
    || die "CT ${CT_ID}: Debian Security simulation failed"
  package_line="$(
    sed -n 's/^Packages that will be upgraded: //p' <<<"${simulation}" | tail -1
  )"
  SECURITY_PACKAGES="$(
    tr ' ' '\n' <<<"${package_line}" | sed '/^$/d' | sort -u
  )"
  if [[ -z "${SECURITY_PACKAGES}" ]]; then
    SECURITY_COUNT=0
  else
    SECURITY_COUNT="$(wc -l <<<"${SECURITY_PACKAGES}" | tr -d ' ')"
  fi
}

pause_apt_daily() {
  local attempt
  log_info "Temporarily pausing the CT ${CT_ID} package-metadata timer"
  pct exec "${CT_ID}" -- systemctl stop apt-daily.timer
  APT_DAILY_TIMER_PAUSED=1
  for ((attempt=1; attempt<=60; attempt++)); do
    if ! pct exec "${CT_ID}" -- systemctl is-active --quiet apt-daily.service; then
      return 0
    fi
    (( attempt == 1 )) \
      && log_info "Waiting for the current CT ${CT_ID} metadata refresh to finish"
    sleep 2
  done
  die "CT ${CT_ID}: apt-daily.service did not finish within 120 seconds"
}

snapshot_capability_preflight() {
  local node
  node="$(hostname -s)"
  pvesh get "/nodes/${node}/lxc/${CT_ID}/feature" \
      --feature snapshot --output-format json 2>/dev/null \
    | grep -Eq '"hasFeature"[[:space:]]*:[[:space:]]*1' \
    || die "CT ${CT_ID} does not support Proxmox snapshots with its current configuration"
}

snapshot_preflight() {
  local rootfs storage used snapshot_count
  rootfs="$(pct config "${CT_ID}" | awk -F': ' '$1 == "rootfs" {print $2}')"
  storage="${rootfs%%:*}"
  [[ -n "${storage}" ]] || die "Could not determine CT ${CT_ID} root storage"
  used="$(
    pvesm status | awk -v storage="${storage}" \
      '$1 == storage {gsub(/%/, "", $7); print int($7)}'
  )"
  [[ "${used}" =~ ^[0-9]+$ ]] || die "Could not determine ${storage} usage"
  (( used < MAX_STORAGE_USED_PERCENT )) \
    || die "${storage} is ${used}% used; limit is ${MAX_STORAGE_USED_PERCENT}%"

  snapshot_count="$(pct listsnapshot "${CT_ID}" | awk '$2 != "current" {count++} END {print count+0}')"
  (( snapshot_count == 0 )) \
    || die "CT ${CT_ID} already has a snapshot; resolve it before patching"
  [[ ! -f "${STATE_FILE}" ]] \
    || die "CT ${CT_ID} already has managed update state; run --cleanup or inspect ${STATE_FILE}"
  log_info "Snapshot preflight passed: ${storage}=${used}% used, existing snapshots=0"
}

backup_preflight() {
  local filesystem_size filesystem_available estimate required minimum_free
  [[ ! -f "${STATE_FILE}" ]] \
    || die "CT ${CT_ID} already has managed update state; run --cleanup or inspect ${STATE_FILE}"
  mkdir -p -m 0700 "${BACKUP_ROOT}"
  chmod 0700 "${BACKUP_ROOT}"
  read -r filesystem_size filesystem_available < <(
    df -B1 --output=size,avail "${BACKUP_ROOT}" | tail -1
  )
  estimate="$(
    pct exec "${CT_ID}" -- df -B1 --output=used / \
      | awk 'NR == 2 {print $1}'
  )"
  [[ "${filesystem_size}" =~ ^[0-9]+$ \
      && "${filesystem_available}" =~ ^[0-9]+$ \
      && "${estimate}" =~ ^[0-9]+$ ]] \
    || die "Could not determine CT ${CT_ID} backup capacity"
  minimum_free="$((filesystem_size * BACKUP_MIN_FREE_PERCENT / 100))"
  required="$((estimate + estimate * BACKUP_HEADROOM_PERCENT / 100 + minimum_free))"
  (( filesystem_available >= required )) \
    || die "Insufficient disk space for CT ${CT_ID} rollback backup"
  log_info "Backup preflight passed: available=${filesystem_available}, required=${required}"
}

validate_ct_backup() {
  local archive_config current_mp0 archived_mp0
  [[ -d "${BACKUP_DIR}" && -f "${BACKUP_DIR}/.owner" ]] \
    || die "CT ${CT_ID} rollback backup ownership marker is missing"
  [[ -s "${BACKUP_ARCHIVE}" && -f "${BACKUP_DIR}/SHA256SUMS" ]] \
    || die "CT ${CT_ID} rollback archive is incomplete"
  (cd "${BACKUP_DIR}" && sha256sum -c SHA256SUMS)
  zstd -t --quiet "${BACKUP_ARCHIVE}" \
    || die "CT ${CT_ID} rollback archive failed compression validation"
  archive_config="$(
    tar --zstd -xOf "${BACKUP_ARCHIVE}" ./etc/vzdump/pct.conf
  )" \
    || die "Could not extract CT ${CT_ID} configuration from rollback archive"
  grep -q '^rootfs:' <<<"${archive_config}" \
    || die "Rollback archive does not contain a root filesystem definition"
  current_mp0="$(pct config "${CT_ID}" | sed -n 's/^mp0: //p')"
  archived_mp0="$(sed -n 's/^mp0: //p' <<<"${archive_config}")"
  [[ -n "${current_mp0}" && "${archived_mp0}" == "${current_mp0}" ]] \
    || die "Rollback archive does not preserve the CT ${CT_ID} media bind mount"
}

create_ct_backup() {
  local owner file
  owner="${SNAPSHOT_PREFIX}-$(date +%Y%m%d-%H%M%S)-${TARGET}"
  BACKUP_DIR="${BACKUP_ROOT}/${owner}"
  mkdir -m 0700 "${BACKUP_DIR}"
  printf '%s\n' "${TARGET}:${CT_ID}:${owner}" >"${BACKUP_DIR}/.owner"
  chmod 0600 "${BACKUP_DIR}/.owner"

  STAGE="backup"
  log_warn "Creating stopped full-rootfs rollback backup for CT ${CT_ID}"
  BACKUP_STAGING_DIR="$(
    mktemp -d "$(dirname "${BACKUP_ROOT}")/.pbsec-ct200.XXXXXX"
  )"
  chmod 0755 "${BACKUP_STAGING_DIR}"
  NEEDS_START=1
  (
    umask 0022
    vzdump "${CT_ID}" --mode stop --compress zstd \
      --dumpdir "${BACKUP_STAGING_DIR}"
  )
  wait_running || die "CT ${CT_ID} did not return after its rollback backup"
  NEEDS_START=0
  mapfile -t staged_files < <(
    find "${BACKUP_STAGING_DIR}" -maxdepth 1 -type f
  )
  (( ${#staged_files[@]} > 0 )) || die "CT ${CT_ID} backup produced no files"
  for file in "${staged_files[@]}"; do
    mv -- "${file}" "${BACKUP_DIR}/"
    chmod 0600 "${BACKUP_DIR}/$(basename "${file}")"
  done
  rmdir "${BACKUP_STAGING_DIR}"
  BACKUP_STAGING_DIR=""
  mapfile -t archives < <(
    find "${BACKUP_DIR}" -maxdepth 1 -type f \
      -name "vzdump-lxc-${CT_ID}-*.tar.zst" -size +0c
  )
  (( ${#archives[@]} == 1 )) \
    || die "Expected exactly one CT ${CT_ID} rollback archive"
  BACKUP_ARCHIVE="${archives[0]}"
  (
    cd "${BACKUP_DIR}"
    sha256sum -- "$(basename "${BACKUP_ARCHIVE}")" >SHA256SUMS
    chmod 0600 SHA256SUMS
  )
  validate_ct_backup
  touch "${BACKUP_DIR}/.validated"
  chmod 0600 "${BACKUP_DIR}/.validated"
  BACKUP_CREATED=1
  write_state created backup
  log_info "Validated CT ${CT_ID} rollback backup: ${BACKUP_ARCHIVE}"
}

cleanup_snapshot() {
  local saved_target saved_ct saved_snapshot created_epoch result age
  [[ -f "${STATE_FILE}" ]] \
    || die "No managed security-update snapshot is recorded for ${TARGET}"
  saved_target="$(state_value target)"
  saved_ct="$(state_value ct_id)"
  saved_snapshot="$(state_value snapshot)"
  created_epoch="$(state_value created_epoch)"
  result="$(state_value result)"
  [[ "${saved_target}" == "${TARGET}" && "${saved_ct}" == "${CT_ID}" ]] \
    || die "Managed snapshot state does not match ${TARGET}"
  [[ "${saved_snapshot}" == "${SNAPSHOT_PREFIX}-"*"-${TARGET}" ]] \
    || die "Managed snapshot name is invalid"
  [[ "${created_epoch}" =~ ^[0-9]+$ ]] || die "Managed snapshot timestamp is invalid"
  [[ "${result}" == "success" ]] \
    || die "The update result is ${result}; failed updates require manual inspection"
  age="$(( $(date +%s) - created_epoch ))"
  (( age >= MIN_SNAPSHOT_AGE_SECONDS )) \
    || die "Snapshot is only $((age / 3600)) hour(s) old; wait 24 hours before cleanup"
  snapshot_exists "${saved_snapshot}" \
    || die "Recorded snapshot does not exist: ${saved_snapshot}"

  run_baseline
  log_warn "Deleting verified managed snapshot: ${saved_snapshot}"
  pct delsnapshot "${CT_ID}" "${saved_snapshot}"
  rm -f -- "${STATE_FILE}"
  log_info "CT ${CT_ID} snapshot cleanup completed successfully"
}

cleanup_backup() {
  local saved_target saved_ct saved_type saved_dir saved_archive
  local created_epoch result age owner expected_owner
  [[ -f "${STATE_FILE}" ]] \
    || die "No managed security-update backup is recorded for ${TARGET}"
  saved_target="$(state_value target)"
  saved_ct="$(state_value ct_id)"
  saved_type="$(state_value protection_type)"
  saved_dir="$(state_value backup_dir)"
  saved_archive="$(state_value backup_archive)"
  created_epoch="$(state_value created_epoch)"
  result="$(state_value result)"
  [[ "${saved_target}" == "${TARGET}" && "${saved_ct}" == "${CT_ID}" \
      && "${saved_type}" == "backup" ]] \
    || die "Managed backup state does not match ${TARGET}"
  [[ "${saved_dir}" == "${BACKUP_ROOT}/${SNAPSHOT_PREFIX}-"*"-${TARGET}" \
      && "${saved_archive}" == "${saved_dir}/vzdump-lxc-${CT_ID}-"*".tar.zst" ]] \
    || die "Managed backup path is invalid"
  [[ "${created_epoch}" =~ ^[0-9]+$ ]] \
    || die "Managed backup timestamp is invalid"
  [[ "${result}" == "success" ]] \
    || die "The update result is ${result}; failed updates require manual inspection"
  [[ -d "${saved_dir}" && -f "${saved_dir}/.owner" ]] \
    || die "Managed backup directory or ownership marker is missing"
  owner="$(<"${saved_dir}/.owner")"
  expected_owner="${TARGET}:${CT_ID}:$(basename "${saved_dir}")"
  [[ "${owner}" == "${expected_owner}" ]] \
    || die "Managed backup ownership marker is invalid"
  BACKUP_DIR="${saved_dir}"
  BACKUP_ARCHIVE="${saved_archive}"
  validate_ct_backup
  age="$(( $(date +%s) - created_epoch ))"
  (( age >= MIN_SNAPSHOT_AGE_SECONDS )) \
    || die "Backup is only $((age / 3600)) hour(s) old; wait 24 hours before cleanup"

  run_baseline
  log_warn "Deleting verified managed rollback backup: ${saved_dir}"
  rm -rf -- "${saved_dir}"
  rm -f -- "${STATE_FILE}"
  log_info "CT ${CT_ID} rollback-backup cleanup completed successfully"
}

while (($#)); do
  case "$1" in
    --dry-run|--confirm|--cleanup)
      [[ -z "${MODE}" ]] || { usage; die "Choose exactly one mode"; }
      MODE="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage
      die "Unknown option: $1"
      ;;
    *)
      [[ -z "${TARGET}" ]] || { usage; die "Specify exactly one target"; }
      TARGET="${1,,}"
      shift
      ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "Run as root"
[[ -n "${TARGET}" && -n "${MODE}" ]] || { usage; die "Target and mode are required"; }
case "${TARGET}" in
  ct200) CT_ID="${DOCKER_CT_ID:-200}" ;;
  ct210) CT_ID="${MQTT_CT_ID:-210}" ;;
  ct220) CT_ID="${HERMES_CT_ID:-220}" ;;
  ctid) die "CTID is a placeholder; use ct200, ct210, or ct220" ;;
  vm100|ct100|homeassistant|haos)
    die "VM 100 is Home Assistant OS and is not supported by this CT updater"
    ;;
  *) die "Unknown target: ${TARGET}" ;;
esac
[[ "${MIN_SNAPSHOT_AGE_SECONDS}" =~ ^[0-9]+$ ]] \
  || die "SECURITY_UPDATE_SNAPSHOT_MIN_AGE_SECONDS must be numeric"
[[ "${MAX_STORAGE_USED_PERCENT}" =~ ^[1-9][0-9]*$ ]] \
  || die "SECURITY_UPDATE_MAX_STORAGE_USED_PERCENT must be positive"
for value in BACKUP_HEADROOM_PERCENT BACKUP_MIN_FREE_PERCENT; do
  [[ "${!value}" =~ ^[0-9]+$ ]] || die "${value} must be numeric"
done
STATE_FILE="${STATE_DIR}/${TARGET}.state"
if [[ "${TARGET}" == "ct200" ]]; then
  PROTECTION_TYPE="backup"
else
  PROTECTION_TYPE="snapshot"
fi
for cmd in apt-get awk basename df find flock grep hostname mktemp mv pct \
    pvesh pvesm rmdir sha256sum sort tar vzdump zstd; do
  command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"
done

exec 9>/run/lock/proxmox-bootstrap-security-update.lock
flock -n 9 || die "Another security-update operation is running"
exec 8>/run/lock/proxmox-bootstrap-backup.lock
flock -n 8 || die "A backup or restore operation is running"

if [[ "${MODE}" == "--cleanup" ]]; then
  if [[ "${PROTECTION_TYPE}" == "backup" ]]; then
    cleanup_backup
  else
    cleanup_snapshot
  fi
  exit 0
fi

pct status "${CT_ID}" | grep -q 'status: running' || die "CT ${CT_ID} is not running"
if [[ "${PROTECTION_TYPE}" == "snapshot" ]]; then
  snapshot_capability_preflight
fi
bash "${STEP20_UPDATE_SCRIPT_DIR}/step20g-unattended-upgrades-validation.sh" "${TARGET}"
pause_apt_daily

log_info "Refreshing package metadata in CT ${CT_ID}"
pct exec "${CT_ID}" -- apt-get update >/dev/null
security_plan
log_info "Debian Security updates pending in CT ${CT_ID}: ${SECURITY_COUNT}"
if (( SECURITY_COUNT > 0 )); then
  sed 's/^/  /' <<<"${SECURITY_PACKAGES}"
fi

if (( SECURITY_COUNT == 0 )); then
  log_info "No security updates are pending; no rollback protection or service change is needed"
  exit 0
fi

if [[ "${PROTECTION_TYPE}" == "backup" ]]; then
  backup_preflight
else
  snapshot_preflight
fi
run_baseline
if [[ "${MODE}" == "--dry-run" ]]; then
  log_info "Dry run passed; no rollback protection, package, reboot, or service change occurred"
  log_info "Next command: bash scripts/step20-update-ct.sh ${TARGET} --confirm"
  exit 0
fi

PROTECTION_CREATED_EPOCH="$(date +%s)"
PROTECTION_CREATED_AT="$(date --iso-8601=seconds)"
if [[ "${PROTECTION_TYPE}" == "backup" ]]; then
  create_ct_backup
else
  SNAPSHOT="${SNAPSHOT_PREFIX}-$(date +%Y%m%d-%H%M%S)-${TARGET}"
  STAGE="snapshot"
  log_warn "Stopping CT ${CT_ID} for a consistent snapshot"
  NEEDS_START=1
  pct shutdown "${CT_ID}" --timeout 60
  pct status "${CT_ID}" | grep -q 'status: stopped' || die "CT ${CT_ID} did not stop"
  pct snapshot "${CT_ID}" "${SNAPSHOT}" \
    --description "Pre-security-update snapshot for ${TARGET}"
  SNAPSHOT_CREATED=1
  write_state created snapshot

  log_info "Starting CT ${CT_ID}"
  pct start "${CT_ID}"
  wait_running || die "CT ${CT_ID} did not return to a stable running state"
  NEEDS_START=0
fi

STAGE="post-protection-baseline"
run_baseline

STAGE="security-update"
log_warn "Installing Debian Security updates in CT ${CT_ID}"
pct exec "${CT_ID}" -- unattended-upgrade --verbose
wait_running || die "CT ${CT_ID} did not remain available after the update"

STAGE="reboot"
if pct exec "${CT_ID}" -- test -e /var/run/reboot-required; then
  log_warn "CT ${CT_ID} requires a reboot"
  pct reboot "${CT_ID}"
  wait_running || die "CT ${CT_ID} did not return after reboot"
else
  log_info "No reboot is required"
fi

STAGE="final-validation"
run_baseline

STAGE="complete"
write_state success complete
cleanup_time="$(date -d "@$((PROTECTION_CREATED_EPOCH + MIN_SNAPSHOT_AGE_SECONDS))" \
  '+%Y-%m-%d %H:%M %Z')"
log_info "Security update completed successfully"
log_info "Rollback protection retained until at least: ${cleanup_time}"
log_info "Cleanup command: bash scripts/step20-update-ct.sh ${TARGET} --cleanup"
