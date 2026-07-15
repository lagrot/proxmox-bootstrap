#!/usr/bin/env bash
set -euo pipefail

BACKUP_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${BACKUP_SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

export LOG_FILE="${BACKUP_LOG_FILE:-/var/log/proxmox-bootstrap/backup.log}"
source "${PROJECT_ROOT}/lib/common.sh"

BACKUP_ROOT="${BACKUP_ROOT:-/var/lib/vz/dump/homelab-backups}"
BACKUP_RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-8}"
BACKUP_MIN_ESTIMATE_BYTES="${BACKUP_MIN_ESTIMATE_BYTES:-10737418240}"
BACKUP_HEADROOM_PERCENT="${BACKUP_HEADROOM_PERCENT:-25}"
BACKUP_MIN_FREE_PERCENT="${BACKUP_MIN_FREE_PERCENT:-20}"
BACKUP_STATUS_DIR="${BACKUP_STATUS_DIR:-/var/lib/proxmox-bootstrap}"
BACKUP_STATUS_FILE="${BACKUP_STATUS_FILE:-${BACKUP_STATUS_DIR}/backup-status.json}"
BACKUP_LAST_SUCCESS_FILE="${BACKUP_LAST_SUCCESS_FILE:-${BACKUP_STATUS_DIR}/backup-last-success}"
LOCK_FILE="/run/lock/proxmox-bootstrap-backup.lock"
START_EPOCH="$(date +%s)"
START_AT="$(date --iso-8601=seconds)"
CURRENT_RUN=""
STAGE="preflight"
RESULT_FILE=""
STATUS_WRITTEN=0

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/ }"
  printf '%s' "${value}"
}

write_status() {
  local result="$1" message="$2" end_epoch duration latest_success="" last_success_at="" backup_size=0 validation="not_run" temp
  end_epoch="$(date +%s)"
  duration="$((end_epoch - START_EPOCH))"
  [[ -f "${BACKUP_LAST_SUCCESS_FILE}" ]] && latest_success="$(<"${BACKUP_LAST_SUCCESS_FILE}")"
  if [[ -n "${latest_success}" && -f "${latest_success}/.validated" ]]; then
    last_success_at="$(date --iso-8601=seconds -r "${latest_success}/.validated")"
  fi
  [[ -n "${CURRENT_RUN}" && -d "${CURRENT_RUN}" ]] && backup_size="$(du -sb "${CURRENT_RUN}" | awk '{print $1}')"
  [[ "${result}" == "success" ]] && validation="passed"
  temp="${BACKUP_STATUS_FILE}.tmp"
  printf '{\n  "schema_version": 1,\n  "last_attempt_at": "%s",\n  "completed_at": "%s",\n  "status": "%s",\n  "stage": "%s",\n  "message": "%s",\n  "backup_directory": "%s",\n  "backup_size_bytes": %d,\n  "validation": "%s",\n  "last_success_at": "%s",\n  "last_successful_backup": "%s",\n  "duration_seconds": %d\n}\n' \
    "${START_AT}" \
    "$(date --iso-8601=seconds)" \
    "$(json_escape "${result}")" \
    "$(json_escape "${STAGE}")" \
    "$(json_escape "${message}")" \
    "$(json_escape "${CURRENT_RUN}")" \
    "${backup_size}" \
    "${validation}" \
    "$(json_escape "${last_success_at}")" \
    "$(json_escape "${latest_success}")" \
    "${duration}" > "${temp}"
  chmod 600 "${temp}"
  mv -f "${temp}" "${BACKUP_STATUS_FILE}"
}

fail() {
  local message="$1"
  log_error "${message}"
  if [[ -n "${CURRENT_RUN}" && -d "${CURRENT_RUN}" && ! -f "${CURRENT_RUN}/.validated" ]]; then
    log_warn "Removing unvalidated backup: ${CURRENT_RUN}"
    rm -rf -- "${CURRENT_RUN}"
  fi
  write_status "failed" "${message}"
  STATUS_WRITTEN=1
  exit 1
}

on_exit() {
  local rc=$?
  [[ -n "${RESULT_FILE}" ]] && rm -f -- "${RESULT_FILE}"
  if [[ "${rc}" -ne 0 && "${STATUS_WRITTEN}" -eq 0 ]]; then
    set +e
    log_error "Unexpected failure during backup stage: ${STAGE}"
    if [[ -n "${CURRENT_RUN}" && -d "${CURRENT_RUN}" && ! -f "${CURRENT_RUN}/.validated" ]]; then
      log_warn "Removing unvalidated backup: ${CURRENT_RUN}"
      rm -rf -- "${CURRENT_RUN}"
    fi
    write_status "failed" "Unexpected failure during ${STAGE}"
  fi
  exit "${rc}"
}
trap on_exit EXIT

[[ "${EUID}" -eq 0 ]] || die "Run as root"
for value in BACKUP_RETENTION_COUNT BACKUP_MIN_ESTIMATE_BYTES BACKUP_HEADROOM_PERCENT BACKUP_MIN_FREE_PERCENT; do
  [[ "${!value}" =~ ^[0-9]+$ ]] || die "${value} must be numeric"
done
(( BACKUP_RETENTION_COUNT > 0 )) || die "BACKUP_RETENTION_COUNT must be positive"
for cmd in flock find du df sort; do command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"; done

mkdir -p "${BACKUP_ROOT}" "$(dirname "${LOG_FILE}")" "${BACKUP_STATUS_DIR}"
chmod 700 "${BACKUP_ROOT}" "${BACKUP_STATUS_DIR}"
touch "${LOG_FILE}"
chmod 640 "${LOG_FILE}"
chown root:adm "${LOG_FILE}" 2>/dev/null || chown root:root "${LOG_FILE}"

exec 9>"${LOCK_FILE}"
flock -n 9 || fail "Another backup operation is already running"

latest_validated="$(find "${BACKUP_ROOT}" -mindepth 2 -maxdepth 2 -type f -name .validated -printf '%h\n' | sort | tail -1)"
estimate="${BACKUP_MIN_ESTIMATE_BYTES}"
if [[ -n "${latest_validated}" ]]; then
  estimate="$(du -sb "${latest_validated}" | awk '{print $1}')"
elif [[ -f "${BACKUP_LAST_SUCCESS_FILE}" ]]; then
  candidate="$(<"${BACKUP_LAST_SUCCESS_FILE}")"
  [[ -d "${candidate}" ]] && estimate="$(du -sb "${candidate}" | awk '{print $1}')"
fi
read -r filesystem_size filesystem_available < <(df -B1 --output=size,avail "${BACKUP_ROOT}" | tail -1)
estimated_with_headroom="$((estimate + estimate * BACKUP_HEADROOM_PERCENT / 100))"
minimum_free_after="$((filesystem_size * BACKUP_MIN_FREE_PERCENT / 100))"
required_available="$((estimated_with_headroom + minimum_free_after))"
log_info "Backup preflight: available=${filesystem_available} estimated=${estimate} required=${required_available}"
(( filesystem_available >= required_available )) \
  || fail "Insufficient disk headroom for a safe backup"

STAGE="backup"
RESULT_FILE="$(mktemp /run/proxmox-bootstrap-backup-result.XXXXXX)"
if ! BACKUP_LOCK_HELD=1 BACKUP_RESULT_FILE="${RESULT_FILE}" bash "${BACKUP_SCRIPT_DIR}/step12-backup.sh"; then
  fail "Backup archive creation failed"
fi
CURRENT_RUN="$(<"${RESULT_FILE}")"
[[ -d "${CURRENT_RUN}" ]] || fail "Backup script did not return a valid run directory"

STAGE="validation"
if ! bash "${BACKUP_SCRIPT_DIR}/step12-backup-validation.sh" "${CURRENT_RUN}"; then
  fail "Backup checksum or extraction validation failed"
fi
[[ -f "${CURRENT_RUN}/.validated" ]] || fail "Validation did not mark the backup as validated"

STAGE="retention"
mapfile -t validated_runs < <(
  find "${BACKUP_ROOT}" -mindepth 2 -maxdepth 2 -type f -name .validated -printf '%h\n' | sort -r
)
if (( ${#validated_runs[@]} > BACKUP_RETENTION_COUNT )); then
  for old_run in "${validated_runs[@]:BACKUP_RETENTION_COUNT}"; do
    log_info "Removing expired validated backup: ${old_run}"
    rm -rf -- "${old_run}"
  done
fi

printf '%s\n' "${CURRENT_RUN}" > "${BACKUP_LAST_SUCCESS_FILE}"
chmod 600 "${BACKUP_LAST_SUCCESS_FILE}"
STAGE="complete"
write_status "success" "Backup and validation completed successfully"
STATUS_WRITTEN=1
log_info "Backup operation completed successfully: ${CURRENT_RUN}"
