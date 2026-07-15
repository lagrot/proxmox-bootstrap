#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"

[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in install systemctl systemd-analyze logrotate; do
  command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"
done

systemd-analyze verify \
  "${PROJECT_ROOT}/config/proxmox-bootstrap-backup.service" \
  "${PROJECT_ROOT}/config/proxmox-bootstrap-backup.timer"
logrotate --debug "${PROJECT_ROOT}/config/proxmox-bootstrap-backup.logrotate" >/dev/null

install -o root -g root -m 0644 \
  "${PROJECT_ROOT}/config/proxmox-bootstrap-backup.service" \
  /etc/systemd/system/proxmox-bootstrap-backup.service
install -o root -g root -m 0644 \
  "${PROJECT_ROOT}/config/proxmox-bootstrap-backup.timer" \
  /etc/systemd/system/proxmox-bootstrap-backup.timer
install -o root -g root -m 0644 \
  "${PROJECT_ROOT}/config/proxmox-bootstrap-backup.logrotate" \
  /etc/logrotate.d/proxmox-bootstrap-backup
install -d -o root -g adm -m 0750 /var/log/proxmox-bootstrap
install -d -o root -g root -m 0700 /var/lib/proxmox-bootstrap
touch /var/log/proxmox-bootstrap/backup.log
chown root:adm /var/log/proxmox-bootstrap/backup.log
chmod 0640 /var/log/proxmox-bootstrap/backup.log

systemctl daemon-reload
systemctl enable --now proxmox-bootstrap-backup.timer
log_info "Backup timer installed and enabled"
systemctl list-timers proxmox-bootstrap-backup.timer --no-pager
