#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"

errors=0
check() { if "$@"; then log_info "PASS: $*"; else log_error "FAIL: $*"; ((errors+=1)); fi; }

[[ "${EUID}" -eq 0 ]] || die "Run as root"
check systemd-analyze verify /etc/systemd/system/proxmox-bootstrap-update-audit.service /etc/systemd/system/proxmox-bootstrap-update-audit.timer
check cmp -s "${PROJECT_ROOT}/config/proxmox-bootstrap-update-audit.service" /etc/systemd/system/proxmox-bootstrap-update-audit.service
check cmp -s "${PROJECT_ROOT}/config/proxmox-bootstrap-update-audit.timer" /etc/systemd/system/proxmox-bootstrap-update-audit.timer
check cmp -s "${PROJECT_ROOT}/config/proxmox-bootstrap-update-audit.logrotate" /etc/logrotate.d/proxmox-bootstrap-update-audit
check cmp -s "${PROJECT_ROOT}/config/proxmox-bootstrap-update-maintenance.logrotate" /etc/logrotate.d/proxmox-bootstrap-update-maintenance
check systemctl is-enabled --quiet proxmox-bootstrap-update-audit.timer
check systemctl is-active --quiet proxmox-bootstrap-update-audit.timer
check logrotate --debug /etc/logrotate.d/proxmox-bootstrap-update-audit
check logrotate --debug /etc/logrotate.d/proxmox-bootstrap-update-maintenance
check test -f "${UPDATE_LOG_FILE}"
check test "$(stat -c %a "${UPDATE_LOG_FILE}")" = 640
check test -f "${UPDATE_STATUS_FILE}"
check test "$(stat -c %a "${UPDATE_STATUS_FILE}")" = 600
check test -f "${UPDATE_MAINTENANCE_LOG_FILE}"
check test "$(stat -c %a "${UPDATE_MAINTENANCE_LOG_FILE}")" = 640
check python3 -m json.tool "${UPDATE_STATUS_FILE}"
check grep -qE '"status": "(success|warning)"' "${UPDATE_STATUS_FILE}"
check bash "${PROJECT_ROOT}/scripts/step20b-update-plan.sh" proxmox
check bash "${PROJECT_ROOT}/scripts/step20f-update-target.sh" ct210 --dry-run
systemctl list-timers proxmox-bootstrap-update-audit.timer --no-pager
(( errors == 0 )) || die "Update operations validation failed with ${errors} error(s)"
log_info "Update operations validation completed successfully"
