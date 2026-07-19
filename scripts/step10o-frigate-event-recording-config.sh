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

log_info "================================================"
log_info "STEP 10O - FRIGATE EVENT-ONLY RECORDING CONFIG"
log_info "================================================"

FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
FRIGATE_CONFIG_FILE="${FRIGATE_CONFIG_FILE:-/opt/frigate/config/config.yml}"
EVENT_RECORDING_DAYS="${FRIGATE_EVENT_RECORDING_DAYS:-10}"
EVENT_PRE_CAPTURE_SECONDS="${FRIGATE_EVENT_PRE_CAPTURE_SECONDS:-5}"
EVENT_POST_CAPTURE_SECONDS="${FRIGATE_EVENT_POST_CAPTURE_SECONDS:-5}"

for value_name in EVENT_RECORDING_DAYS EVENT_PRE_CAPTURE_SECONDS EVENT_POST_CAPTURE_SECONDS; do
  value="${!value_name}"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    log_error "${value_name} must be a non-negative integer"
    exit 1
  fi
done

if [[ "${EVENT_RECORDING_DAYS}" -eq 0 ]]; then
  log_error "EVENT_RECORDING_DAYS must be greater than zero"
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

if ! pct status "${FRIGATE_CT_ID}" 2>/dev/null | grep -q "status: running"; then
  log_error "CT ${FRIGATE_CT_ID} is not running"
  exit 1
fi

if ! pct exec "${FRIGATE_CT_ID}" -- test -f "${FRIGATE_CONFIG_FILE}"; then
  log_error "Frigate config file does not exist: ${FRIGATE_CONFIG_FILE}"
  exit 1
fi

log_info "Updating global recording retention without changing cameras, zones, or masks..."
pct exec "${FRIGATE_CT_ID}" -- python3 - \
  "${FRIGATE_CONFIG_FILE}" \
  "${EVENT_RECORDING_DAYS}" \
  "${EVENT_PRE_CAPTURE_SECONDS}" \
  "${EVENT_POST_CAPTURE_SECONDS}" <<'PY'
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
retention_days = sys.argv[2]
pre_capture = sys.argv[3]
post_capture = sys.argv[4]

lines = config_path.read_text().splitlines()
record_block = [
    "record:",
    "  enabled: true",
    "  continuous:",
    "    days: 0",
    "  motion:",
    "    days: 0",
    "  alerts:",
    f"    pre_capture: {pre_capture}",
    f"    post_capture: {post_capture}",
    "    retain:",
    f"      days: {retention_days}",
    "      mode: motion",
    "  detections:",
    f"    pre_capture: {pre_capture}",
    f"    post_capture: {post_capture}",
    "    retain:",
    f"      days: {retention_days}",
    "      mode: motion",
]

record_start = next((idx for idx, line in enumerate(lines) if line == "record:"), None)
if record_start is None:
    insert_at = next(
        (idx for idx, line in enumerate(lines) if re.match(r"^(snapshots|cameras|version):", line)),
        len(lines),
    )
    rendered = lines[:insert_at] + record_block + [""] + lines[insert_at:]
else:
    record_end = len(lines)
    for idx in range(record_start + 1, len(lines)):
        if lines[idx] and not lines[idx].startswith((" ", "#")):
            record_end = idx
            break
    rendered = lines[:record_start] + record_block + lines[record_end:]

new_content = "\n".join(rendered).rstrip() + "\n"
old_content = config_path.read_text()
if new_content == old_content:
    raise SystemExit(0)

backup_path = config_path.with_name(config_path.name + ".bak-event-recording")
backup_path.write_text(old_content)
config_path.write_text(new_content)
PY

log_info "Event-only policy configured:"
log_info "  Continuous video retention: 0 days"
log_info "  Motion-only video retention: 0 days"
log_info "  Alert/detection video retention: ${EVENT_RECORDING_DAYS} days"
log_info "  Event capture: ${EVENT_PRE_CAPTURE_SECONDS}s before and ${EVENT_POST_CAPTURE_SECONDS}s after"
log_info "Restart Frigate with scripts/step10e-frigate-restart.sh"
log_info "Then validate with scripts/step10p-frigate-event-recording-validation.sh"
