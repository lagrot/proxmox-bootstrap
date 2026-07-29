#!/usr/bin/env bash
set -euo pipefail
umask 0077

STEP20_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${STEP20_SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

export LOG_FILE="${UPDATE_MAINTENANCE_LOG_FILE:-/var/log/proxmox-bootstrap/update-maintenance.log}"
source "${PROJECT_ROOT}/lib/common.sh"

TARGET=""
DRY_RUN=0
CONFIRM_UPDATE=0
CT_ID=""
SNAPSHOT=""
TRANSACTION_ID=""
TRANSACTION_DIR=""
STAGE="preflight"
SNAPSHOT_CREATED=false
NEEDS_START=false
STATUS_WRITTEN=0
START_AT="$(date --iso-8601=seconds)"
START_EPOCH="$(date +%s)"
UPDATE_TRANSACTION_ROOT="${UPDATE_TRANSACTION_ROOT:-/var/lib/proxmox-bootstrap/update-transactions}"
UPDATE_SNAPSHOT_RETENTION_DAYS="${UPDATE_SNAPSHOT_RETENTION_DAYS:-7}"
UPDATE_SNAPSHOT_PREFIX="${UPDATE_SNAPSHOT_PREFIX:-pbupd}"
UPDATE_LVM_MAX_USED_PERCENT="${UPDATE_LVM_MAX_USED_PERCENT:-80}"

usage() {
  cat <<EOF
Usage: $0 TARGET (--dry-run | --confirm-update)

Targets: ct200, ct210, ct220 (case-insensitive)

--dry-run        Verify gates and show the package transaction; do not stop,
                 snapshot, update, reboot, or validate the target.
--confirm-update Create a stopped-state snapshot, update one CT, reboot when
                 required, and run the matching regression suite.
EOF
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/ }"
  printf '%s' "${value}"
}

write_status() {
  local result="$1" message="$2" temp duration
  [[ -n "${TRANSACTION_DIR}" ]] || return 0
  duration="$(( $(date +%s) - START_EPOCH ))"
  temp="${TRANSACTION_DIR}/status.json.tmp"
  printf '{\n  "schema_version": 1,\n  "transaction_id": "%s",\n  "target": "%s",\n  "ct_id": %d,\n  "snapshot": "%s",\n  "started_at": "%s",\n  "completed_at": "%s",\n  "status": "%s",\n  "stage": "%s",\n  "message": "%s",\n  "snapshot_created": %s,\n  "duration_seconds": %d\n}\n' \
    "$(json_escape "${TRANSACTION_ID}")" "$(json_escape "${TARGET}")" "${CT_ID}" \
    "$(json_escape "${SNAPSHOT}")" "${START_AT}" "$(date --iso-8601=seconds)" \
    "$(json_escape "${result}")" "$(json_escape "${STAGE}")" \
    "$(json_escape "${message}")" "${SNAPSHOT_CREATED}" "${duration}" >"${temp}"
  chmod 0600 "${temp}"
  mv -f "${temp}" "${TRANSACTION_DIR}/status.json"
}

fail() {
  local message="$1"
  log_error "${message}"
  write_status failed "${message}"
  STATUS_WRITTEN=1
  if [[ "${SNAPSHOT_CREATED}" == true ]]; then
    log_warn "Snapshot ${SNAPSHOT} retained; inspect before explicit Step 20G rollback"
  fi
  exit 1
}

on_exit() {
  local rc=$?
  if [[ "${NEEDS_START}" == true ]]; then
    set +e
    log_warn "Attempting to restart CT ${CT_ID} after interrupted maintenance"
    pct start "${CT_ID}" >/dev/null 2>&1 || true
  fi
  if (( rc != 0 && STATUS_WRITTEN == 0 )) && [[ -n "${TRANSACTION_DIR}" ]]; then
    set +e
    write_status failed "Unexpected failure during ${STAGE}"
    [[ "${SNAPSHOT_CREATED}" == true ]] \
      && log_warn "Snapshot ${SNAPSHOT} retained after unexpected failure"
  fi
  exit "${rc}"
}
trap on_exit EXIT

ct_for_target() {
  case "$1" in
    ct200) printf '%s\n' "${DOCKER_CT_ID:-200}" ;;
    ct210) printf '%s\n' "${MQTT_CT_ID:-210}" ;;
    ct220) printf '%s\n' "${HERMES_CT_ID:-220}" ;;
    *) return 1 ;;
  esac
}

wait_running() {
  local attempt
  for attempt in $(seq 1 30); do
    pct status "${CT_ID}" | grep -q 'status: running' && return 0
    sleep 1
  done
  return 1
}

backup_gate() {
  local latest_backup backup_age
  [[ -f "${BACKUP_STATUS_FILE}" && -f "${BACKUP_LAST_SUCCESS_FILE}" ]] \
    || fail "Step 12 backup status is unavailable"
  grep -q '"status": "success"' "${BACKUP_STATUS_FILE}" \
    || fail "Latest Step 12 backup operation was not successful"
  latest_backup="$(<"${BACKUP_LAST_SUCCESS_FILE}")"
  [[ -d "${latest_backup}" && -f "${latest_backup}/.validated" ]] \
    || fail "Latest Step 12 backup is not validated"
  backup_age="$(( $(date +%s) - $(stat -c %Y "${latest_backup}/.validated") ))"
  (( backup_age <= UPDATE_MAX_BACKUP_AGE_DAYS * 86400 )) \
    || fail "Latest validated backup is older than ${UPDATE_MAX_BACKUP_AGE_DAYS} days"
  log_info "Validated Step 12 backup: ${latest_backup}"
}

snapshot_capacity_gate() {
  local rootfs storage used managed_count
  rootfs="$(pct config "${CT_ID}" | awk -F': ' '$1=="rootfs"{print $2}')"
  storage="${rootfs%%:*}"
  [[ -n "${storage}" ]] || fail "Could not determine CT ${CT_ID} root storage"
  used="$(pvesm status | awk -v target="${storage}" '$1==target {gsub(/%/,"",$7); print int($7)}')"
  [[ "${used}" =~ ^[0-9]+$ ]] || fail "Could not determine ${storage} utilization"
  (( used < UPDATE_LVM_MAX_USED_PERCENT )) \
    || fail "${storage} usage is ${used}%; snapshot limit is ${UPDATE_LVM_MAX_USED_PERCENT}%"
  log_info "Snapshot storage ${storage}: ${used}% used, limit ${UPDATE_LVM_MAX_USED_PERCENT}%"
  managed_count="$(pct listsnapshot "${CT_ID}" | awk -v prefix="${UPDATE_SNAPSHOT_PREFIX}-" '$2 ~ ("^" prefix) {count++} END {print count+0}')"
  (( managed_count < 2 )) \
    || fail "CT ${CT_ID} already has ${managed_count} managed maintenance snapshots; resolve or remove one first"
  log_info "Managed maintenance snapshots for CT ${CT_ID}: ${managed_count}/2"
}

cleanup_expired_snapshots() {
  local dir status target ct snapshot completed_epoch cutoff
  cutoff="$(( $(date +%s) - UPDATE_SNAPSHOT_RETENTION_DAYS * 86400 ))"
  [[ -d "${UPDATE_TRANSACTION_ROOT}" ]] || return 0
  for dir in "${UPDATE_TRANSACTION_ROOT}"/*; do
    [[ -f "${dir}/status.json" ]] || continue
    status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "${dir}/status.json")"
    [[ "${status}" == success ]] || continue
    target="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("target",""))' "${dir}/status.json")"
    ct="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("ct_id",""))' "${dir}/status.json")"
    snapshot="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("snapshot",""))' "${dir}/status.json")"
    completed_epoch="$(date -d "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("completed_at",""))' "${dir}/status.json")" +%s 2>/dev/null || printf '0')"
    [[ "${target}" =~ ^ct(200|210|220)$ && "${ct}" =~ ^(200|210|220)$ ]] || continue
    [[ "${snapshot}" == "${UPDATE_SNAPSHOT_PREFIX}-"* ]] || continue
    (( completed_epoch > 0 && completed_epoch < cutoff )) || continue
    if pct listsnapshot "${ct}" | awk '{print $2}' | grep -Fxq "${snapshot}"; then
      log_info "Removing expired successful maintenance snapshot: CT ${ct} ${snapshot}"
      pct delsnapshot "${ct}" "${snapshot}"
    fi
  done
}

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --confirm-update) CONFIRM_UPDATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) die "Unknown option: $1" ;;
    *)
      [[ -z "${TARGET}" ]] || die "Only one target may be supplied"
      TARGET="${1,,}"
      shift
      ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "Run as root"
[[ -n "${TARGET}" ]] || { usage; exit 1; }
CT_ID="$(ct_for_target "${TARGET}")" || die "Unsupported automated update target: ${TARGET}"
(( DRY_RUN + CONFIRM_UPDATE == 1 )) || die "Choose exactly one of --dry-run or --confirm-update"
for value in UPDATE_MAX_BACKUP_AGE_DAYS UPDATE_SNAPSHOT_RETENTION_DAYS UPDATE_LVM_MAX_USED_PERCENT; do
  [[ "${!value}" =~ ^[1-9][0-9]*$ ]] || die "${value} must be a positive integer"
done
for cmd in apt-get awk date flock pct pvesm python3 seq; do
  command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"
done

mkdir -p -m 0700 "${UPDATE_TRANSACTION_ROOT}" "$(dirname "${LOG_FILE}")"
touch "${LOG_FILE}"
chown root:adm "${LOG_FILE}" 2>/dev/null || chown root:root "${LOG_FILE}"
chmod 0640 "${LOG_FILE}"

exec 9>/run/lock/proxmox-bootstrap-update-maintenance.lock
flock -n 9 || die "Another update maintenance operation is running"
exec 8>/run/lock/proxmox-bootstrap-backup.lock
flock -n 8 || die "A Step 12 backup or restore operation is running"

TRANSACTION_ID="$(date +%Y%m%d-%H%M%S)-${TARGET}"
SNAPSHOT="${UPDATE_SNAPSHOT_PREFIX}-${TRANSACTION_ID}"
TRANSACTION_DIR="${UPDATE_TRANSACTION_ROOT}/${TRANSACTION_ID}"
mkdir -m 0700 "${TRANSACTION_DIR}"
write_status planning "Maintenance preflight started"

log_info "======================================"
log_info "STEP 20F - CONTROLLED CT UPDATE"
log_info "======================================"
log_info "Transaction: ${TRANSACTION_ID}"
log_info "Target: ${TARGET} (CT ${CT_ID})"
[[ "$(pct status "${CT_ID}")" == *"status: running"* ]] || fail "CT ${CT_ID} must be running"
backup_gate
snapshot_capacity_gate

STAGE="package-plan"
log_info "Refreshing target package metadata"
pct exec "${CT_ID}" -- apt-get update >/dev/null || fail "APT metadata refresh failed"
log_info "Refreshing the cross-system audit without another metadata update"
UPDATE_AUDIT_REFRESH=0 bash "${STEP20_SCRIPT_DIR}/step20a-update-audit.sh" >/dev/null \
  || fail "Cross-system update audit failed"
pct exec "${CT_ID}" -- apt-get -s dist-upgrade >"${TRANSACTION_DIR}/package-plan.txt" \
  || fail "APT package simulation failed"
chmod 0600 "${TRANSACTION_DIR}/package-plan.txt"
PENDING_COUNT="$(awk '/^Inst / {count++} END {print count+0}' "${TRANSACTION_DIR}/package-plan.txt")"
log_info "Pending package operations: ${PENDING_COUNT}"
awk '/^Inst / {print "  " $0}' "${TRANSACTION_DIR}/package-plan.txt"

if (( DRY_RUN == 1 )); then
  STAGE="dry-run"
  log_info "Would stop CT ${CT_ID} cleanly"
  log_info "Would create snapshot ${SNAPSHOT}"
  log_info "Would restart CT ${CT_ID} and run its baseline validation"
  log_info "Would preserve local configuration files and install all pending stable updates"
  log_info "Would reboot CT ${CT_ID} if /var/run/reboot-required exists"
  log_info "Would run Step 20C regression validation and a final audit"
  log_info "Only APT package metadata and protected transaction records were refreshed"
  log_info "No snapshot, package installation, reboot, or service change occurred"
  write_status dry_run "Dry run completed successfully"
  STATUS_WRITTEN=1
  printf '\nDRY RUN PASSED\n'
  printf '%s\n' '=============='
  printf 'Target:             %s (CT %s)\n' "${TARGET}" "${CT_ID}"
  printf 'Pending packages:   %s\n' "${PENDING_COUNT}"
  printf 'Package plan:       %s/package-plan.txt\n' "${TRANSACTION_DIR}"
  printf '\nNEXT STEP — starts real maintenance and causes a brief outage:\n'
  printf 'bash scripts/step20f-update-target.sh %s --confirm-update\n' "${TARGET}"
  printf '\nAfter completion:\n'
  printf 'bash scripts/step20-status.sh\n\n'
  exit 0
fi

(( PENDING_COUNT > 0 )) || {
  STAGE="complete"
  write_status success "No pending packages; no snapshot or update was needed"
  STATUS_WRITTEN=1
  log_info "No pending packages; maintenance completed without changes"
  exit 0
}

STAGE="snapshot"
cleanup_expired_snapshots
log_info "Stopping CT ${CT_ID} for a consistent pre-update snapshot"
NEEDS_START=true
pct shutdown "${CT_ID}" --timeout 60 || fail "CT ${CT_ID} did not shut down cleanly"
[[ "$(pct status "${CT_ID}")" == *"status: stopped"* ]] || fail "CT ${CT_ID} is not stopped"
pct snapshot "${CT_ID}" "${SNAPSHOT}" \
  --description "Step 20 pre-update snapshot ${TRANSACTION_ID}" \
  || fail "Failed to create pre-update snapshot"
SNAPSHOT_CREATED=true
write_status snapshot_created "Pre-update snapshot created"

log_info "Starting CT ${CT_ID}"
pct start "${CT_ID}" || fail "Failed to start CT ${CT_ID} after snapshot"
wait_running || fail "CT ${CT_ID} did not return to running state"
NEEDS_START=false
sleep 3

STAGE="baseline-validation"
bash "${STEP20_SCRIPT_DIR}/step20c-post-update-validation.sh" "${TARGET}" \
  || fail "Pre-update baseline validation failed"

STAGE="package-update"
log_info "Installing pending stable updates while preserving local configuration files"
pct exec "${CT_ID}" -- env DEBIAN_FRONTEND=noninteractive \
  apt-get -y -o Dpkg::Options::=--force-confold dist-upgrade \
  | tee "${TRANSACTION_DIR}/package-update.txt" \
  || fail "APT update failed"
chmod 0600 "${TRANSACTION_DIR}/package-update.txt"

mapfile -t config_candidates < <(pct exec "${CT_ID}" -- find /etc -xdev -type f \
  \( -name '*.dpkg-dist' -o -name '*.dpkg-new' \) -print 2>/dev/null || true)
if (( ${#config_candidates[@]} > 0 )); then
  printf '%s\n' "${config_candidates[@]}" >"${TRANSACTION_DIR}/package-config-review.txt"
  chmod 0600 "${TRANSACTION_DIR}/package-config-review.txt"
  log_warn "Package configuration candidates require review; recorded in transaction"
fi

STAGE="reboot"
if pct exec "${CT_ID}" -- test -e /var/run/reboot-required; then
  log_info "Reboot marker detected; rebooting CT ${CT_ID}"
  pct reboot "${CT_ID}" || fail "Failed to reboot CT ${CT_ID}"
  wait_running || fail "CT ${CT_ID} did not return after reboot"
  sleep 5
else
  log_info "No CT reboot marker detected"
fi

STAGE="post-validation"
bash "${STEP20_SCRIPT_DIR}/step20c-post-update-validation.sh" "${TARGET}" \
  || fail "Post-update regression validation failed"

STAGE="final-audit"
UPDATE_AUDIT_REFRESH=0 bash "${STEP20_SCRIPT_DIR}/step20a-update-audit.sh" \
  || fail "Final update audit failed"

STAGE="complete"
write_status success "Update and regression validation completed successfully"
STATUS_WRITTEN=1
log_info "Update completed successfully"
log_info "Snapshot ${SNAPSHOT} will remain for ${UPDATE_SNAPSHOT_RETENTION_DAYS} days"
log_info "Transaction record: ${TRANSACTION_DIR}"
