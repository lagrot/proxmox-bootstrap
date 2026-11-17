#!/usr/bin/env bash
set -euo pipefail
umask 0077

if [[ "${1:-}" == "--dry-run" && $# -eq 1 ]]; then
  echo 'Would back up HAOS, a consistent live Frigate SQLite snapshot, MQTT, Hermes and CT240; then validate using Step 12B.'
  exit 0
fi
[[ $# -eq 0 ]] || { echo 'Usage: bash scripts/step12-backup.sh [--dry-run]' >&2; exit 2; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

HA_VM_ID="${HA_VM_ID:-100}"
FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
MQTT_CT_ID="${MQTT_CT_ID:-210}"
HERMES_CT_ID="${HERMES_CT_ID:-220}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/lib/vz/dump/homelab-backups}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${BACKUP_ROOT}/${RUN_ID}"
BACKUP_RESULT_FILE="${BACKUP_RESULT_FILE:-}"
BACKUP_LOCK_HELD="${BACKUP_LOCK_HELD:-0}"
RUN_COMPLETE=0
HERMES_PAUSED=0
HERMES_DASHBOARD_PAUSED=0
FRIGATE_STAGE=""

cleanup() {
  [[ -z "${FRIGATE_STAGE}" ]] || rm -rf -- "${FRIGATE_STAGE}"
  if [[ "${HERMES_PAUSED}" -eq 1 ]]; then
    pct exec "${HERMES_CT_ID}" -- systemctl start hermes-gateway.service >/dev/null 2>&1 \
      || log_error "Could not restart Hermes gateway during backup cleanup"
  fi
  if [[ "${HERMES_DASHBOARD_PAUSED}" -eq 1 ]]; then
    pct exec "${HERMES_CT_ID}" -- systemctl start hermes-dashboard.service >/dev/null 2>&1 \
      || log_error "Could not restart Hermes dashboard during backup cleanup"
  fi
  if [[ "${RUN_COMPLETE}" -ne 1 && -d "${RUN_DIR}" ]]; then
    log_warn "Removing incomplete backup: ${RUN_DIR}"
    rm -rf -- "${RUN_DIR}"
  fi
}
trap cleanup EXIT

[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in flock pct qm vzdump tar sha256sum find; do
  command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"
done
if [[ "${BACKUP_LOCK_HELD}" -ne 1 ]]; then
  exec 8>/run/lock/proxmox-bootstrap-backup.lock
  flock -n 8 || die "Another backup or restore operation is already running"
fi
mkdir -p "${RUN_DIR}"
chmod 700 "${BACKUP_ROOT}" "${RUN_DIR}"

log_info "Creating Home Assistant VM backup"
qm status "${HA_VM_ID}" >/dev/null
vzdump "${HA_VM_ID}" --mode snapshot --compress zstd --dumpdir "${RUN_DIR}" --quiet 1

archive_ct() {
  local id="$1" name="$2"; shift 2
  log_info "Backing up ${name} configuration"
  pct status "${id}" | grep -q 'status: running' || die "CT ${id} is not running"
  pct exec "${id}" -- tar -czf - "$@" > "${RUN_DIR}/${name}.tar.gz"
  chmod 600 "${RUN_DIR}/${name}.tar.gz"
}

log_info "Backing up Frigate configuration and a consistent SQLite snapshot"
pct status "${FRIGATE_CT_ID}" | grep -q 'status: running' || die "Frigate CT is not running"
FRIGATE_STAGE="$(mktemp -d "${BACKUP_ROOT}/.frigate-stage.XXXXXXXX")"
pct exec "${FRIGATE_CT_ID}" -- tar -C / -cf - \
  --exclude=opt/frigate/config/frigate.db \
  --exclude=opt/frigate/config/frigate.db-wal \
  --exclude=opt/frigate/config/frigate.db-shm \
  opt/frigate/docker-compose.yml opt/frigate/config | tar -C "${FRIGATE_STAGE}" -xf -
pct exec "${FRIGATE_CT_ID}" -- python3 -c "$(cat "${PROJECT_ROOT}/lib/frigate-sqlite-snapshot.py")" \
  /opt/frigate/config/frigate.db > "${FRIGATE_STAGE}/opt/frigate/config/frigate.db"
printf '%s\n' 'sqlite-online-backup-v1' > "${FRIGATE_STAGE}/opt/frigate/config/.backup-sqlite-format"
tar -C "${FRIGATE_STAGE}" -czf "${RUN_DIR}/frigate.tar.gz" opt/frigate/docker-compose.yml opt/frigate/config
chmod 600 "${RUN_DIR}/frigate.tar.gz"
rm -rf -- "${FRIGATE_STAGE}"
FRIGATE_STAGE=""
archive_ct "${MQTT_CT_ID}" mosquitto /etc/mosquitto

log_info "Pausing active Hermes services for a consistent state backup"
if pct exec "${HERMES_CT_ID}" -- systemctl is-active --quiet hermes-dashboard.service; then
  HERMES_DASHBOARD_PAUSED=1
  pct exec "${HERMES_CT_ID}" -- systemctl stop hermes-dashboard.service
fi
HERMES_PAUSED=1
pct exec "${HERMES_CT_ID}" -- systemctl stop hermes-gateway.service
archive_ct "${HERMES_CT_ID}" hermes \
  /opt/hermes /home/hermes/.hermes /etc/systemd/system/hermes-gateway.service
pct exec "${HERMES_CT_ID}" -- systemctl start hermes-gateway.service
pct exec "${HERMES_CT_ID}" -- systemctl is-active --quiet hermes-gateway.service \
  || die "Hermes gateway did not restart"
HERMES_PAUSED=0
if [[ "${HERMES_DASHBOARD_PAUSED}" -eq 1 ]]; then
  pct exec "${HERMES_CT_ID}" -- systemctl start hermes-dashboard.service
  pct exec "${HERMES_CT_ID}" -- systemctl is-active --quiet hermes-dashboard.service \
    || die "Hermes dashboard did not restart"
  HERMES_DASHBOARD_PAUSED=0
fi

BACKUP_LOCK_HELD=1 bash "${PROJECT_ROOT}/scripts/step24-landet-recovery.sh" --backup "${RUN_DIR}"

(cd "${RUN_DIR}" && sha256sum -- * > SHA256SUMS)
chmod 600 "${RUN_DIR}/SHA256SUMS"
if [[ -n "${BACKUP_RESULT_FILE}" ]]; then
  printf '%s\n' "${RUN_DIR}" > "${BACKUP_RESULT_FILE}"
  chmod 600 "${BACKUP_RESULT_FILE}"
fi
RUN_COMPLETE=1
log_info "Backup archives created: ${RUN_DIR}"
log_info "Run step12-backup-validation.sh before treating this backup as validated"
