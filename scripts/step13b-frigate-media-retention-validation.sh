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

log_info "========================================================"
log_info "STEP 13B - FRIGATE MEDIA RETENTION VALIDATION"
log_info "========================================================"

FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
FRIGATE_INTERNAL_PORT="${FRIGATE_INTERNAL_PORT:-5000}"
FRIGATE_MEDIA_DIR="${FRIGATE_MOUNTPOINT:-/mnt/frigate}"
SNAPSHOT_DAYS="${FRIGATE_SNAPSHOT_RETENTION_DAYS:-10}"
EXPORT_WARN_DAYS="${FRIGATE_EXPORT_WARN_AGE_DAYS:-30}"
MEDIA_WARN_PERCENT="${FRIGATE_MEDIA_WARN_PERCENT:-80}"
CAMERA_NAMES=(
  "${TAPO_C200_NAME:-${TAPO_CAMERA_NAME:-tplink_c200_1}}"
  "${TAPO_C320WS_NAME:-tplink_c320ws_1}"
)

VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0

record_error() {
  log_error "$1"
  ((VALIDATION_ERRORS+=1))
}

record_warning() {
  log_warn "$1"
  ((VALIDATION_WARNINGS+=1))
}

human_bytes() {
  local bytes="$1"
  awk -v bytes="${bytes}" 'BEGIN {
    split("B KiB MiB GiB TiB", units, " "); value=bytes; unit=1;
    while (value >= 1024 && unit < 5) { value /= 1024; unit++ }
    if (unit == 1) printf "%d %s", value, units[unit];
    else printf "%.1f %s", value, units[unit]
  }'
}

for value_name in SNAPSHOT_DAYS EXPORT_WARN_DAYS MEDIA_WARN_PERCENT; do
  value="${!value_name}"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    log_error "${value_name} must be a non-negative integer"
    exit 1
  fi
done
if (( SNAPSHOT_DAYS < 1 )); then
  log_error "FRIGATE_SNAPSHOT_RETENTION_DAYS must be greater than zero"
  exit 1
fi
if (( EXPORT_WARN_DAYS < 1 )); then
  log_error "FRIGATE_EXPORT_WARN_AGE_DAYS must be greater than zero"
  exit 1
fi
if (( MEDIA_WARN_PERCENT < 1 || MEDIA_WARN_PERCENT > 100 )); then
  log_error "FRIGATE_MEDIA_WARN_PERCENT must be between 1 and 100"
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

for cmd in pct grep awk curl date; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Required command not found: ${cmd}"
    exit 1
  fi
done

if ! pct status "${FRIGATE_CT_ID}" 2>/dev/null | grep -q "status: running"; then
  log_error "CT ${FRIGATE_CT_ID} is not running"
  exit 1
fi

HEALTH="$(pct exec "${FRIGATE_CT_ID}" -- docker inspect \
  --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' frigate 2>/dev/null || true)"
if [[ "${HEALTH}" == "healthy" ]]; then
  log_info "Frigate container is healthy"
else
  record_error "Unexpected Frigate container health: ${HEALTH:-unknown}"
fi

FRIGATE_IP="$(pct exec "${FRIGATE_CT_ID}" -- ip -4 -o addr show dev eth0 2>/dev/null \
  | awk '{ split($4, addr, "/"); print addr[1]; exit }' || true)"
CONFIG_JSON=""
if [[ -n "${FRIGATE_IP}" ]]; then
  CONFIG_JSON="$(curl -fsS --max-time 15 \
    "http://${FRIGATE_IP}:${FRIGATE_INTERNAL_PORT}/api/config" || true)"
fi

log_info "Checking effective snapshot retention for both cameras..."
if [[ -z "${CONFIG_JSON}" ]]; then
  record_error "Could not read effective Frigate configuration"
else
  API_CONFIG_FILE="$(pct exec "${FRIGATE_CT_ID}" -- mktemp /tmp/frigate-media-retention.XXXXXX)"
  trap 'pct exec "${FRIGATE_CT_ID}" -- rm -f "${API_CONFIG_FILE}" >/dev/null 2>&1 || true' EXIT
  printf '%s' "${CONFIG_JSON}" | pct exec "${FRIGATE_CT_ID}" -- bash -c \
    "umask 077; cat > '${API_CONFIG_FILE}'"

  if pct exec "${FRIGATE_CT_ID}" -- python3 - \
    "${API_CONFIG_FILE}" "${SNAPSHOT_DAYS}" "${CAMERA_NAMES[@]}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
expected = float(sys.argv[2])
cameras = sys.argv[3:]
errors = []

snapshots = config.get("snapshots", {})
if not snapshots.get("enabled"):
    errors.append("global snapshots are disabled")
if float(snapshots.get("retain", {}).get("default", -1)) != expected:
    errors.append(f"global snapshot retention is not {expected:g} days")

for name in cameras:
    camera = config.get("cameras", {}).get(name)
    if camera is None:
        errors.append(f"camera missing: {name}")
        continue
    camera_snapshots = camera.get("snapshots", {})
    if not camera_snapshots.get("enabled"):
        errors.append(f"{name}: snapshots are disabled")
    if float(camera_snapshots.get("retain", {}).get("default", -1)) != expected:
        errors.append(f"{name}: effective snapshot retention is not {expected:g} days")

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
  then
    log_info "Both cameras use ${SNAPSHOT_DAYS}-day snapshot retention"
  else
    record_error "Effective snapshot retention does not match policy"
  fi
fi

log_info "Auditing dedicated Frigate SSD capacity..."
read -r MEDIA_TOTAL MEDIA_USED MEDIA_AVAILABLE MEDIA_PERCENT < <(
  pct exec "${FRIGATE_CT_ID}" -- df -P -B1 "${FRIGATE_MEDIA_DIR}" \
    | awk 'NR==2 { gsub(/%/, "", $5); print $2, $3, $4, $5 }'
)
log_info "Media SSD: $(human_bytes "${MEDIA_USED}") used of $(human_bytes "${MEDIA_TOTAL}") (${MEDIA_PERCENT}%)"
if (( MEDIA_PERCENT >= MEDIA_WARN_PERCENT )); then
  record_warning "Media SSD usage is at or above ${MEDIA_WARN_PERCENT}%"
fi

log_info "Auditing Frigate snapshot/clip storage..."
read -r CLIP_COUNT CLIP_BYTES < <(
  pct exec "${FRIGATE_CT_ID}" -- sh -c \
    "count=\$(find '${FRIGATE_MEDIA_DIR}/clips' -type f 2>/dev/null | wc -l); bytes=\$(du -sb '${FRIGATE_MEDIA_DIR}/clips' 2>/dev/null | awk '{print \$1}'); printf '%s %s\n' \"\$count\" \"\${bytes:-0}\""
)
log_info "Snapshot/clip storage: ${CLIP_COUNT} files, $(human_bytes "${CLIP_BYTES}")"

log_info "Auditing operator-managed exports without deleting files..."
EXPORT_STATS="$(pct exec "${FRIGATE_CT_ID}" -- python3 - \
  "${FRIGATE_MEDIA_DIR}/exports" "${EXPORT_WARN_DAYS}" <<'PY'
import pathlib
import sys
import time

root = pathlib.Path(sys.argv[1])
warn_days = int(sys.argv[2])
files = [path for path in root.rglob("*") if path.is_file()] if root.exists() else []
total = sum(path.stat().st_size for path in files)
if files:
    oldest = min(files, key=lambda path: path.stat().st_mtime)
    epoch = int(oldest.stat().st_mtime)
    name = oldest.name.replace("|", "_")
else:
    epoch = 0
    name = "none"
cutoff = time.time() - warn_days * 86400
old_count = sum(path.stat().st_mtime < cutoff for path in files)
print(f"{len(files)}|{total}|{epoch}|{name}|{old_count}")
PY
)"
IFS='|' read -r EXPORT_COUNT EXPORT_BYTES OLDEST_EPOCH OLDEST_NAME OLD_EXPORT_COUNT <<< "${EXPORT_STATS}"
log_info "Exports: ${EXPORT_COUNT} files, $(human_bytes "${EXPORT_BYTES}")"
if (( EXPORT_COUNT > 0 )); then
  OLDEST_DATE="$(date -d "@${OLDEST_EPOCH}" '+%Y-%m-%d %H:%M:%S %Z')"
  log_info "Oldest export: ${OLDEST_NAME} (${OLDEST_DATE})"
fi
if (( OLD_EXPORT_COUNT > 0 )); then
  record_warning "${OLD_EXPORT_COUNT} export(s) are older than ${EXPORT_WARN_DAYS} days; review manually"
fi
log_info "No exports were modified or deleted"

log_info "============================================="
log_info "FRIGATE MEDIA RETENTION VALIDATION SUMMARY"
log_info "============================================="
log_info "Validation warnings: ${VALIDATION_WARNINGS}"
log_info "Validation errors: ${VALIDATION_ERRORS}"

if (( VALIDATION_ERRORS > 0 )); then
  log_error "Frigate media retention validation failed"
  exit 1
fi
if (( VALIDATION_WARNINGS > 0 )); then
  log_warn "Frigate media retention validation completed with warnings"
else
  log_info "Frigate media retention validation completed successfully"
fi
