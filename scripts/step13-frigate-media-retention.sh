#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"
if [[ -f "${PROJECT_ROOT}/config/local.conf" ]]; then
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/config/local.conf"
fi

log_info "============================================="
log_info "STEP 13 - FRIGATE MEDIA RETENTION"
log_info "============================================="

FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
FRIGATE_APP_DIR="${FRIGATE_APP_DIR:-/opt/frigate}"
FRIGATE_CONFIG_FILE="${FRIGATE_CONFIG_FILE:-/opt/frigate/config/config.yml}"
SNAPSHOT_DAYS="${FRIGATE_SNAPSHOT_RETENTION_DAYS:-10}"
CANDIDATE_FILE="${FRIGATE_CONFIG_FILE}.candidate-media-retention"
BACKUP_FILE="${FRIGATE_CONFIG_FILE}.bak-media-retention"
VALIDATION_DIR="/tmp/frigate-media-retention-validation"

if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

if [[ ! "${SNAPSHOT_DAYS}" =~ ^[0-9]+$ ]] || (( SNAPSHOT_DAYS < 1 )); then
  log_error "FRIGATE_SNAPSHOT_RETENTION_DAYS must be a positive integer"
  exit 1
fi

for cmd in pct grep seq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Required command not found: ${cmd}"
    exit 1
  fi
done

if ! pct status "${FRIGATE_CT_ID}" 2>/dev/null | grep -q "status: running"; then
  log_error "CT ${FRIGATE_CT_ID} is not running"
  exit 1
fi

if ! pct exec "${FRIGATE_CT_ID}" -- test -f "${FRIGATE_CONFIG_FILE}"; then
  log_error "Frigate config file does not exist: ${FRIGATE_CONFIG_FILE}"
  exit 1
fi

cleanup() {
  pct exec "${FRIGATE_CT_ID}" -- rm -f "${CANDIDATE_FILE}" >/dev/null 2>&1 || true
  pct exec "${FRIGATE_CT_ID}" -- rm -rf "${VALIDATION_DIR}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log_info "Building a candidate with ${SNAPSHOT_DAYS}-day global snapshot retention..."
pct exec "${FRIGATE_CT_ID}" -- python3 - \
  "${FRIGATE_CONFIG_FILE}" "${CANDIDATE_FILE}" "${SNAPSHOT_DAYS}" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
candidate = pathlib.Path(sys.argv[2])
days = sys.argv[3]
lines = source.read_text(encoding="utf-8").splitlines()

snapshot_block = [
    "snapshots:",
    "  enabled: true",
    "  retain:",
    f"    default: {days}",
]

def indentation(line):
    return len(line) - len(line.lstrip(" "))

start = next((i for i, line in enumerate(lines) if line == "snapshots:"), None)
if start is None:
    insert_at = next(
        (i for i, line in enumerate(lines) if line.startswith(("cameras:", "version:"))),
        len(lines),
    )
    lines = lines[:insert_at] + snapshot_block + [""] + lines[insert_at:]
else:
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i] and not lines[i].lstrip().startswith("#") and indentation(lines[i]) == 0:
            end = i
            break
    lines = lines[:start] + snapshot_block + lines[end:]

# Camera-specific snapshot retention overrides defeat the global policy. Remove
# only each nested `retain` subtree and preserve all other snapshot settings.
cameras_start = next((i for i, line in enumerate(lines) if line.startswith("cameras:")), None)
if cameras_start is not None:
    cameras_end = len(lines)
    for i in range(cameras_start + 1, len(lines)):
        if lines[i] and not lines[i].lstrip().startswith("#") and indentation(lines[i]) == 0:
            cameras_end = i
            break

    i = cameras_start + 1
    while i < cameras_end:
        if lines[i].strip() == "snapshots:" and indentation(lines[i]) == 4:
            snapshot_end = cameras_end
            for j in range(i + 1, cameras_end):
                if lines[j] and not lines[j].lstrip().startswith("#") and indentation(lines[j]) <= 4:
                    snapshot_end = j
                    break
            retain_start = next(
                (j for j in range(i + 1, snapshot_end)
                 if lines[j].strip() == "retain:" and indentation(lines[j]) == 6),
                None,
            )
            if retain_start is not None:
                retain_end = snapshot_end
                for j in range(retain_start + 1, snapshot_end):
                    if lines[j] and not lines[j].lstrip().startswith("#") and indentation(lines[j]) <= 6:
                        retain_end = j
                        break
                removed = retain_end - retain_start
                del lines[retain_start:retain_end]
                cameras_end -= removed
                snapshot_end -= removed
            i = snapshot_end
        else:
            i += 1

candidate.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
candidate.chmod(0o600)
PY

if pct exec "${FRIGATE_CT_ID}" -- cmp -s "${FRIGATE_CONFIG_FILE}" "${CANDIDATE_FILE}"; then
  log_info "Snapshot retention is already configured; no restart required"
  log_info "Exports remain operator-managed and are never deleted by this script"
  exit 0
fi

FRIGATE_IMAGE="$(pct exec "${FRIGATE_CT_ID}" -- docker inspect --format '{{.Config.Image}}' frigate)"
log_info "Validating the candidate with ${FRIGATE_IMAGE}..."
pct exec "${FRIGATE_CT_ID}" -- rm -rf "${VALIDATION_DIR}"
pct exec "${FRIGATE_CT_ID}" -- mkdir -m 700 "${VALIDATION_DIR}"
pct exec "${FRIGATE_CT_ID}" -- cp "${CANDIDATE_FILE}" "${VALIDATION_DIR}/config.yml"
pct exec "${FRIGATE_CT_ID}" -- chmod 600 "${VALIDATION_DIR}/config.yml"
if ! pct exec "${FRIGATE_CT_ID}" -- docker run --rm \
  -v "${VALIDATION_DIR}:/config" \
  --entrypoint python3 "${FRIGATE_IMAGE}" \
  -u -m frigate --validate-config >/dev/null; then
  log_error "Candidate Frigate configuration is invalid; active config was not changed"
  exit 1
fi

log_info "Saving the previous config and installing the validated candidate..."
pct exec "${FRIGATE_CT_ID}" -- cp -a "${FRIGATE_CONFIG_FILE}" "${BACKUP_FILE}"
pct exec "${FRIGATE_CT_ID}" -- chmod 600 "${BACKUP_FILE}"
pct exec "${FRIGATE_CT_ID}" -- mv "${CANDIDATE_FILE}" "${FRIGATE_CONFIG_FILE}"

log_info "Restarting Frigate..."
pct exec "${FRIGATE_CT_ID}" -- bash -c \
  "cd '${FRIGATE_APP_DIR}' && docker compose restart frigate"

HEALTH=""
for _ in $(seq 1 45); do
  HEALTH="$(pct exec "${FRIGATE_CT_ID}" -- docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' frigate 2>/dev/null || true)"
  [[ "${HEALTH}" == "healthy" ]] && break
  sleep 2
done

if [[ "${HEALTH}" != "healthy" ]]; then
  log_error "Frigate did not become healthy after restart (status: ${HEALTH:-unknown})"
  log_error "Previous config backup: ${BACKUP_FILE}"
  exit 1
fi

log_info "Frigate is healthy with ${SNAPSHOT_DAYS}-day snapshot retention"
log_info "Exports remain operator-managed and are never deleted by this script"
log_info "Validate with scripts/step13b-frigate-media-retention-validation.sh"
