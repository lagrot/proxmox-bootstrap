#!/usr/bin/env bash
set -euo pipefail

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
BACKUP_RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-7}"
RUN_COMPLETE=0
HERMES_PAUSED=0

cleanup() {
  if [[ "${HERMES_PAUSED}" -eq 1 ]]; then
    pct exec "${HERMES_CT_ID}" -- systemctl start hermes-gateway.service >/dev/null 2>&1 || true
  fi
  if [[ "${RUN_COMPLETE}" -ne 1 && -d "${RUN_DIR}" ]]; then
    log_warn "Removing incomplete backup: ${RUN_DIR}"
    rm -rf -- "${RUN_DIR}"
  fi
}
trap cleanup EXIT

[[ "${EUID}" -eq 0 ]] || die "Run as root"
[[ "${BACKUP_RETENTION_COUNT}" =~ ^[1-9][0-9]*$ ]] \
  || die "BACKUP_RETENTION_COUNT must be a positive integer"
for cmd in pct qm vzdump tar sha256sum find; do
  command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"
done
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

archive_ct "${FRIGATE_CT_ID}" frigate \
  /opt/frigate/docker-compose.yml /opt/frigate/config
archive_ct "${MQTT_CT_ID}" mosquitto /etc/mosquitto

log_info "Pausing Hermes gateway for a consistent state backup"
pct exec "${HERMES_CT_ID}" -- systemctl stop hermes-gateway.service
HERMES_PAUSED=1
archive_ct "${HERMES_CT_ID}" hermes \
  /opt/hermes /home/hermes/.hermes /etc/systemd/system/hermes-gateway.service
pct exec "${HERMES_CT_ID}" -- systemctl start hermes-gateway.service
HERMES_PAUSED=0
pct exec "${HERMES_CT_ID}" -- systemctl is-active --quiet hermes-gateway.service \
  || die "Hermes gateway did not restart"

(cd "${RUN_DIR}" && sha256sum * > SHA256SUMS)
chmod 600 "${RUN_DIR}/SHA256SUMS"
RUN_COMPLETE=1

mapfile -t COMPLETED_RUNS < <(
  find "${BACKUP_ROOT}" -mindepth 2 -maxdepth 2 -type f -name SHA256SUMS \
    -printf '%h\n' | sort -r
)
if (( ${#COMPLETED_RUNS[@]} > BACKUP_RETENTION_COUNT )); then
  for old_run in "${COMPLETED_RUNS[@]:BACKUP_RETENTION_COUNT}"; do
    log_info "Removing expired backup: ${old_run}"
    rm -rf -- "${old_run}"
  done
fi
log_info "Backup completed: ${RUN_DIR}"
