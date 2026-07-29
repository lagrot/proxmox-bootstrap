#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"

[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in install logrotate systemctl systemd-analyze; do
  command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"
done

systemd-analyze verify \
  "${PROJECT_ROOT}/config/proxmox-bootstrap-update-audit.service" \
  "${PROJECT_ROOT}/config/proxmox-bootstrap-update-audit.timer"
logrotate --debug "${PROJECT_ROOT}/config/proxmox-bootstrap-update-audit.logrotate" >/dev/null
logrotate --debug "${PROJECT_ROOT}/config/proxmox-bootstrap-update-maintenance.logrotate" >/dev/null

install -o root -g root -m 0644 \
  "${PROJECT_ROOT}/config/proxmox-bootstrap-update-audit.service" \
  /etc/systemd/system/proxmox-bootstrap-update-audit.service
install -o root -g root -m 0644 \
  "${PROJECT_ROOT}/config/proxmox-bootstrap-update-audit.timer" \
  /etc/systemd/system/proxmox-bootstrap-update-audit.timer
install -o root -g root -m 0644 \
  "${PROJECT_ROOT}/config/proxmox-bootstrap-update-audit.logrotate" \
  /etc/logrotate.d/proxmox-bootstrap-update-audit
install -o root -g root -m 0644 \
  "${PROJECT_ROOT}/config/proxmox-bootstrap-update-maintenance.logrotate" \
  /etc/logrotate.d/proxmox-bootstrap-update-maintenance
install -d -o root -g adm -m 0750 /var/log/proxmox-bootstrap
install -d -o root -g root -m 0700 /var/lib/proxmox-bootstrap
touch /var/log/proxmox-bootstrap/update-audit.log
touch /var/log/proxmox-bootstrap/update-maintenance.log
chown root:adm /var/log/proxmox-bootstrap/update-audit.log
chown root:adm /var/log/proxmox-bootstrap/update-maintenance.log
chmod 0640 /var/log/proxmox-bootstrap/update-audit.log
chmod 0640 /var/log/proxmox-bootstrap/update-maintenance.log

systemctl daemon-reload
systemctl enable --now proxmox-bootstrap-update-audit.timer
log_info "Weekly update-audit timer installed and enabled"
systemctl list-timers proxmox-bootstrap-update-audit.timer --no-pager
