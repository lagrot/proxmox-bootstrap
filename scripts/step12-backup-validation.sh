#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"

BACKUP_ROOT="${BACKUP_ROOT:-/var/lib/vz/dump/homelab-backups}"
RUN_DIR="${1:-}"
[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in find sha256sum tar; do
  command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"
done
if [[ -z "${RUN_DIR}" ]]; then
  RUN_DIR="$(find "${BACKUP_ROOT}" -mindepth 2 -maxdepth 2 -type f \
    -name SHA256SUMS -printf '%h\n' | sort | tail -1)"
fi
[[ -d "${RUN_DIR}" ]] || die "Backup directory not found: ${RUN_DIR}"
[[ -f "${RUN_DIR}/SHA256SUMS" ]] || die "Missing checksum manifest"

log_info "Verifying checksums in ${RUN_DIR}"
(cd "${RUN_DIR}" && sha256sum -c SHA256SUMS)

TEST_DIR="$(mktemp -d /tmp/homelab-backup-restore.XXXXXX)"
trap 'rm -rf "${TEST_DIR}"' EXIT
for archive in "${RUN_DIR}"/frigate.tar.gz "${RUN_DIR}"/mosquitto.tar.gz "${RUN_DIR}"/hermes.tar.gz; do
  [[ -s "${archive}" ]] || die "Missing or empty archive: ${archive}"
  tar -tzf "${archive}" >/dev/null
  tar -xzf "${archive}" -C "${TEST_DIR}"
done
find "${RUN_DIR}" -maxdepth 1 -type f -name 'vzdump-qemu-*.vma.zst' -size +0c | grep -q . || die "Home Assistant vzdump archive missing"
if [[ ! -f "${RUN_DIR}/.validated" ]]; then
  touch "${RUN_DIR}/.validated"
  chmod 600 "${RUN_DIR}/.validated"
fi
log_info "Archive integrity and temporary restore test passed"
