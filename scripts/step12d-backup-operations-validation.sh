#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"

errors=0
check() { if "$@"; then log_info "PASS: $*"; else log_error "FAIL: $*"; ((errors+=1)); fi; }

[[ "${EUID}" -eq 0 ]] || die "Run as root"
check systemd-analyze verify /etc/systemd/system/proxmox-bootstrap-backup.service /etc/systemd/system/proxmox-bootstrap-backup.timer
check cmp -s "${PROJECT_ROOT}/config/proxmox-bootstrap-backup.service" /etc/systemd/system/proxmox-bootstrap-backup.service
check cmp -s "${PROJECT_ROOT}/config/proxmox-bootstrap-backup.timer" /etc/systemd/system/proxmox-bootstrap-backup.timer
check cmp -s "${PROJECT_ROOT}/config/proxmox-bootstrap-backup.logrotate" /etc/logrotate.d/proxmox-bootstrap-backup
check systemctl is-enabled --quiet proxmox-bootstrap-backup.timer
check systemctl is-active --quiet proxmox-bootstrap-backup.timer
check test -f /etc/logrotate.d/proxmox-bootstrap-backup
check logrotate --debug /etc/logrotate.d/proxmox-bootstrap-backup
check test -d "${BACKUP_ROOT}"
check test "$(stat -c %a "${BACKUP_ROOT}")" = 700
check test -f "${BACKUP_LOG_FILE}"
check test "$(stat -c %a "${BACKUP_LOG_FILE}")" = 640
if [[ -f "${BACKUP_STATUS_FILE}" ]]; then
  check python3 -m json.tool "${BACKUP_STATUS_FILE}"
  check grep -q '"status": "success"' "${BACKUP_STATUS_FILE}"
  check test "$(stat -c %a "${BACKUP_STATUS_FILE}")" = 600
else
  log_warn "Status JSON is not present until the first scheduled/manual operation runs"
fi
if [[ -f "${BACKUP_LAST_SUCCESS_FILE}" ]]; then
  latest_success="$(<"${BACKUP_LAST_SUCCESS_FILE}")"
  check test -d "${latest_success}"
  check test -f "${latest_success}/.validated"
else
  log_warn "Last-success pointer is not present until the first successful operation runs"
fi
validated_count="$(find "${BACKUP_ROOT}" -mindepth 2 -maxdepth 2 -type f -name .validated | wc -l)"
check test "${validated_count}" -le "${BACKUP_RETENTION_COUNT}"
systemctl list-timers proxmox-bootstrap-backup.timer --no-pager
(( errors == 0 )) || die "Backup operations validation failed with ${errors} error(s)"
log_info "Backup operations validation completed successfully"
