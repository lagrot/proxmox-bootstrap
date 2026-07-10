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

if ! pct status "${FRIGATE_CT_ID}" 2>/dev/null | grep -q 'status: running'; then
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

FRIGATE_LOGS="$(pct exec "${FRIGATE_CT_ID}" -- docker logs --since 30m frigate 2>&1 || true)"
if grep -qiE 'edgetpu.*(error|failed|unable)|coral.*(error|failed|unable)|failed to load delegate|no device found' <<< "${FRIGATE_LOGS}"; then
  record_error "Recent Frigate logs contain Coral/EdgeTPU errors"
else
  log_info "No recent Coral/EdgeTPU initialization errors found"
fi

if grep -qiE 'detector.*(coral|edgetpu)|edgetpu.*(detector|device)|coral.*(detector|device)' <<< "${FRIGATE_LOGS}"; then
  log_info "Recent Frigate logs mention Coral/EdgeTPU initialization"
else
  record_warn "Recent logs do not mention Coral initialization"
fi

log_info "Checking live Frigate detector statistics..."
STATS_JSON="$(pct exec "${FRIGATE_CT_ID}" -- docker exec frigate python3 -c \
  'import json, urllib.request; print(json.dumps(json.load(urllib.request.urlopen("http://127.0.0.1:5000/api/stats", timeout=5))))' \
  2>/dev/null || true)"

if [[ -z "${STATS_JSON}" ]]; then
  record_warn "Could not read live Frigate stats from the internal API"
else
  STATS_RESULT="$(STATS_JSON="${STATS_JSON}" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["STATS_JSON"])
detectors = data.get("detectors", {})
coral = detectors.get("coral") if isinstance(detectors, dict) else None

if isinstance(coral, dict):
    speed = coral.get("inference_speed")
    pid = coral.get("pid")
    print(f"FOUND|inference_speed={speed}|pid={pid}")
else:
    print("MISSING")
PY
  )"

  case "${STATS_RESULT}" in
    FOUND\|*)
      log_info "Live Coral detector stats: ${STATS_RESULT#FOUND|}"
      ;;
    *)
      record_error "Live Frigate stats do not report a detector named coral"
      ;;
  esac
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
