#!/usr/bin/env bash
set -euo pipefail
umask 0077

STEP20_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${STEP20_SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

export LOG_FILE="${UPDATE_MAINTENANCE_LOG_FILE:-/var/log/proxmox-bootstrap/update-maintenance.log}"
source "${PROJECT_ROOT}/lib/common.sh"

TRANSACTION_ID=""
DRY_RUN=0
CONFIRM_ROLLBACK=0
UPDATE_TRANSACTION_ROOT="${UPDATE_TRANSACTION_ROOT:-/var/lib/proxmox-bootstrap/update-transactions}"
UPDATE_SNAPSHOT_PREFIX="${UPDATE_SNAPSHOT_PREFIX:-pbupd}"

usage() {
  cat <<EOF
Usage: $0 --transaction ID (--dry-run | --confirm-rollback)

Rollback is disruptive and discards CT root-disk changes made after the
pre-update snapshot. It never changes CT 200's /mnt/frigate bind mount.
EOF
}

while (($#)); do
  case "$1" in
    --transaction) [[ $# -ge 2 ]] || die "--transaction requires an ID"; TRANSACTION_ID="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --confirm-rollback) CONFIRM_ROLLBACK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "Run as root"
[[ "${TRANSACTION_ID}" =~ ^[0-9]{8}-[0-9]{6}-ct(200|210|220)$ ]] \
  || die "Invalid transaction ID"
(( DRY_RUN + CONFIRM_ROLLBACK == 1 )) || die "Choose exactly one of --dry-run or --confirm-rollback"
TRANSACTION_DIR="${UPDATE_TRANSACTION_ROOT}/${TRANSACTION_ID}"
STATUS_FILE="${TRANSACTION_DIR}/status.json"
[[ -f "${STATUS_FILE}" ]] || die "Transaction status not found: ${TRANSACTION_ID}"
python3 -m json.tool "${STATUS_FILE}" >/dev/null || die "Transaction status is invalid"

CT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ct_id"])' "${STATUS_FILE}")"
TARGET="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["target"])' "${STATUS_FILE}")"
SNAPSHOT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["snapshot"])' "${STATUS_FILE}")"
[[ "${CT_ID}" =~ ^(200|210|220)$ && "${TARGET}" == "ct${CT_ID}" ]] \
  || die "Transaction target metadata is invalid"
[[ "${SNAPSHOT}" == "${UPDATE_SNAPSHOT_PREFIX}-${TRANSACTION_ID}" ]] \
  || die "Transaction snapshot metadata is invalid"
pct listsnapshot "${CT_ID}" | awk '{print $2}' | grep -Fxq "${SNAPSHOT}" \
  || die "Snapshot is unavailable: CT ${CT_ID} ${SNAPSHOT}"

log_warn "Rollback target: CT ${CT_ID}, snapshot ${SNAPSHOT}"
log_warn "CT root-disk changes after the snapshot will be discarded"
[[ "${CT_ID}" != 200 ]] \
  || log_warn "/mnt/frigate is a bind mount and will not be rolled back"

if (( DRY_RUN == 1 )); then
  log_info "Would stop CT ${CT_ID}, roll back ${SNAPSHOT}, start it, and run ${TARGET} validation"
  log_info "Dry run completed; no runtime state was changed"
  exit 0
fi

exec 9>/run/lock/proxmox-bootstrap-update-maintenance.lock
flock -n 9 || die "Another update maintenance operation is running"
exec 8>/run/lock/proxmox-bootstrap-backup.lock
flock -n 8 || die "A Step 12 backup or restore operation is running"

log_warn "Stopping CT ${CT_ID} for explicit rollback"
pct shutdown "${CT_ID}" --timeout 60
pct rollback "${CT_ID}" "${SNAPSHOT}"
pct start "${CT_ID}"
for _ in $(seq 1 30); do
  pct status "${CT_ID}" | grep -q 'status: running' && break
  sleep 1
done
pct status "${CT_ID}" | grep -q 'status: running' || die "CT ${CT_ID} did not start after rollback"
sleep 5
bash "${STEP20_SCRIPT_DIR}/step20c-post-update-validation.sh" "${TARGET}"

python3 - "${STATUS_FILE}" <<'PY'
import json
import os
import sys
from datetime import datetime

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["status"] = "rolled_back"
data["stage"] = "rollback-complete"
data["message"] = "Explicit rollback and regression validation completed successfully"
data["rolled_back_at"] = datetime.now().astimezone().isoformat(timespec="seconds")
temp = path + ".tmp"
with open(temp, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
os.chmod(temp, 0o600)
os.replace(temp, path)
PY
log_info "Explicit rollback and regression validation completed successfully"
