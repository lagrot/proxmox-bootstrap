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

FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
FRIGATE_CONFIG_FILE="${FRIGATE_CONFIG_FILE:-/opt/frigate/config/config.yml}"
FRIGATE_LOG_LOOKBACK="${FRIGATE_TPU_LOG_LOOKBACK:-30m}"
VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0

record_error() { log_error "$1"; ((VALIDATION_ERRORS+=1)); }
record_warn() { log_warn "$1"; ((VALIDATION_WARNINGS+=1)); }

log_info "=========================================="
log_info "STEP 10I - FRIGATE USB TPU VALIDATION"
log_info "=========================================="

if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

for cmd in pct grep python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    record_error "Required host command not found: ${cmd}"
  fi
done
if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Missing required host commands"
  exit 1
fi
if [[ ! "${FRIGATE_CT_ID}" =~ ^[0-9]+$ ]]; then
  log_error "Docker CT ID must be numeric"
  exit 1
fi
if [[ ! "${FRIGATE_LOG_LOOKBACK}" =~ ^[1-9][0-9]*(s|m|h)$ ]]; then
  log_error "FRIGATE_TPU_LOG_LOOKBACK must be a positive duration ending in s, m, or h"
  exit 1
fi

if ! CT_STATUS="$(pct status "${FRIGATE_CT_ID}" 2>&1)"; then
  log_error "Could not query status for CT ${FRIGATE_CT_ID}: ${CT_STATUS}"
  exit 1
elif [[ "${CT_STATUS}" != *'status: running'* ]]; then
  log_error "CT ${FRIGATE_CT_ID} is not running"
  exit 1
fi
log_info "CT ${FRIGATE_CT_ID} is running"

log_info "Checking Frigate detector configuration..."
if pct exec "${FRIGATE_CT_ID}" -- grep -qE '^detectors:' "${FRIGATE_CONFIG_FILE}" \
  && pct exec "${FRIGATE_CT_ID}" -- grep -qE '^  coral:' "${FRIGATE_CONFIG_FILE}" \
  && pct exec "${FRIGATE_CT_ID}" -- grep -qE '^    type: edgetpu' "${FRIGATE_CONFIG_FILE}" \
  && pct exec "${FRIGATE_CT_ID}" -- grep -qE '^    device: usb' "${FRIGATE_CONFIG_FILE}"; then
  log_info "Frigate is configured for the USB Coral EdgeTPU"
else
  record_error "Frigate config does not contain a USB Coral EdgeTPU detector"
fi

log_info "Checking USB device passthrough into the Frigate container..."
if pct exec "${FRIGATE_CT_ID}" -- docker exec frigate test -d /dev/bus/usb; then
  log_info "USB device bus is visible inside the Frigate container"
else
  record_error "USB device bus is not visible inside the Frigate container"
fi

if FRIGATE_LOGS="$(pct exec "${FRIGATE_CT_ID}" -- docker logs \
  --since "${FRIGATE_LOG_LOOKBACK}" --tail 1000 frigate 2>&1)"; then
  LOGS_READ=1
else
  LOGS_READ=0
  record_warn "Could not read recent Frigate logs"
fi
LOG_HAS_TPU_ERROR=0
LOG_HAS_TPU_INIT=0
if [[ "${LOGS_READ}" -eq 1 ]]; then
  if grep -qiE 'edgetpu.*(error|failed|unable)|coral.*(error|failed|unable)|failed to load delegate|no device found' <<< "${FRIGATE_LOGS}"; then
    LOG_HAS_TPU_ERROR=1
  fi
  if grep -qiE 'detector.*(coral|edgetpu)|edgetpu.*(detector|device)|coral.*(detector|device)' <<< "${FRIGATE_LOGS}"; then
    LOG_HAS_TPU_INIT=1
    log_info "Recent Frigate logs mention Coral/EdgeTPU initialization"
  fi
fi

log_info "Checking live Frigate detector statistics..."
STATS_JSON="$(pct exec "${FRIGATE_CT_ID}" -- docker exec frigate python3 -c \
  'import json, urllib.request; print(json.dumps(json.load(urllib.request.urlopen("http://127.0.0.1:5000/api/stats", timeout=5))))' \
  2>/dev/null || true)"

CORAL_STATS_RESULT="$(STATS_JSON="${STATS_JSON}" python3 - <<'PY'
import json
import math
import os

try:
    raw = os.environ.get("STATS_JSON", "")
    if not raw:
        print("UNAVAILABLE")
        raise SystemExit
    data = json.loads(raw)
except (json.JSONDecodeError, TypeError):
    print("INVALID")
else:
    detectors = data.get("detectors", {}) if isinstance(data, dict) else {}
    coral = detectors.get("coral") if isinstance(detectors, dict) else None
    if not isinstance(coral, dict):
        print("MISSING")
    else:
        speed, pid = coral.get("inference_speed"), coral.get("pid")
        try:
            speed = float(speed)
            pid = int(pid)
        except (TypeError, ValueError):
            print("INVALID")
        else:
            if math.isfinite(speed) and speed > 0 and pid > 0:
                print(f"FOUND|inference_speed={speed:g}|pid={pid}")
            else:
                print("INACTIVE")
PY
)"

case "${CORAL_STATS_RESULT}" in
  FOUND\|*)
    log_info "Live Coral detector stats: ${CORAL_STATS_RESULT#FOUND|}"
    ;;
  MISSING)
    record_error "Live Frigate stats do not report a detector named coral"
    ;;
  INACTIVE)
    record_error "Live Coral detector statistics do not show an active process and positive inference speed"
    ;;
  INVALID)
    record_error "Live Frigate stats are not valid detector data"
    ;;
  UNAVAILABLE)
    record_error "Could not read live Frigate stats from the internal API"
    ;;
  *)
    record_error "Could not read live Frigate stats from the internal API"
    ;;
esac

if [[ "${LOG_HAS_TPU_ERROR}" -eq 1 ]]; then
  if [[ "${CORAL_STATS_RESULT}" == FOUND\|* ]]; then
    record_warn "Recent Coral/EdgeTPU error logs exist, but the live Coral detector is active"
  else
    record_error "Recent Frigate logs contain Coral/EdgeTPU errors"
  fi
elif [[ "${LOGS_READ}" -eq 1 && "${LOG_HAS_TPU_INIT}" -eq 0 ]]; then
  if [[ "${CORAL_STATS_RESULT}" == FOUND\|* ]]; then
    record_warn "Recent logs do not mention Coral initialization; live Coral statistics confirm it is active"
  else
    record_warn "Recent logs do not mention Coral initialization"
  fi
fi

log_info "=========================================="
log_info "USB TPU VALIDATION SUMMARY"
log_info "=========================================="
log_info "Validation warnings: ${VALIDATION_WARNINGS}"
log_info "Validation errors: ${VALIDATION_ERRORS}"

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Frigate USB TPU validation failed"
  exit 1
elif [[ "${VALIDATION_WARNINGS}" -gt 0 ]]; then
  log_warn "Frigate USB TPU validation completed with warnings"
  exit 0
fi

log_info "Frigate USB TPU validation completed successfully"
