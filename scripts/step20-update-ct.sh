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
NEEDS_START=0
STAGE="preflight"
STATE_DIR="${SECURITY_UPDATE_STATE_DIR:-/var/lib/proxmox-bootstrap/security-updates}"
STATE_FILE=""
SNAPSHOT_PREFIX="pbsec"
MIN_SNAPSHOT_AGE_SECONDS="${SECURITY_UPDATE_SNAPSHOT_MIN_AGE_SECONDS:-86400}"
MAX_STORAGE_USED_PERCENT="${SECURITY_UPDATE_MAX_STORAGE_USED_PERCENT:-80}"

usage() {
  cat <<EOF
Usage: $0 TARGET (--dry-run | --confirm | --cleanup)

Targets: ct200, ct210, ct220

  --dry-run  Verify the current service, policy, storage and package plan.
  --confirm  Snapshot one CT, install Debian Security updates and validate it.
  --cleanup  After 24 hours, validate again and remove this script's snapshot.
EOF
}

write_state() {
  local result="$1" stage="$2" temp
  mkdir -p -m 0700 "${STATE_DIR}"
  temp="${STATE_FILE}.tmp"
  printf 'target=%s\nct_id=%s\nsnapshot=%s\ncreated_epoch=%s\ncreated_at=%s\nresult=%s\nstage=%s\n' \
    "${TARGET}" "${CT_ID}" "${SNAPSHOT}" "${SNAPSHOT_CREATED_EPOCH}" \
    "${SNAPSHOT_CREATED_AT}" "${result}" "${stage}" >"${temp}"
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
    pct start "${CT_ID}" >/dev/null 2>&1
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
STATE_FILE="${STATE_DIR}/${TARGET}.state"
for cmd in apt-get awk flock pct pvesm sort; do
  command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"
done

exec 9>/run/lock/proxmox-bootstrap-security-update.lock
flock -n 9 || die "Another security-update operation is running"
exec 8>/run/lock/proxmox-bootstrap-backup.lock
flock -n 8 || die "A backup or restore operation is running"

if [[ "${MODE}" == "--cleanup" ]]; then
  cleanup_snapshot
  exit 0
fi

pct status "${CT_ID}" | grep -q 'status: running' || die "CT ${CT_ID} is not running"
bash "${STEP20_UPDATE_SCRIPT_DIR}/step20g-unattended-upgrades-validation.sh" "${TARGET}"
run_baseline

if [[ "${MODE}" == "--confirm" ]]; then
  log_info "Refreshing package metadata in CT ${CT_ID}"
  pct exec "${CT_ID}" -- apt-get update >/dev/null
fi

security_plan
log_info "Debian Security updates pending in CT ${CT_ID}: ${SECURITY_COUNT}"
if (( SECURITY_COUNT > 0 )); then
  sed 's/^/  /' <<<"${SECURITY_PACKAGES}"
fi

if (( SECURITY_COUNT == 0 )); then
  log_info "No security updates are pending; no snapshot or service change is needed"
  exit 0
fi

snapshot_preflight
if [[ "${MODE}" == "--dry-run" ]]; then
  log_info "Dry run passed; no snapshot, package, reboot, or service change occurred"
  log_info "Next command: bash scripts/step20-update-ct.sh ${TARGET} --confirm"
  exit 0
fi

SNAPSHOT_CREATED_EPOCH="$(date +%s)"
SNAPSHOT_CREATED_AT="$(date --iso-8601=seconds)"
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

STAGE="post-snapshot-baseline"
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
cleanup_time="$(date -d "@$((SNAPSHOT_CREATED_EPOCH + MIN_SNAPSHOT_AGE_SECONDS))" \
  '+%Y-%m-%d %H:%M %Z')"
log_info "Security update completed successfully"
log_info "Snapshot retained until at least: ${cleanup_time}"
log_info "Cleanup command: bash scripts/step20-update-ct.sh ${TARGET} --cleanup"
