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
FRIGATE_APP_DIR="${FRIGATE_APP_DIR:-/opt/frigate}"
FRIGATE_CONFIG_FILE="${FRIGATE_CONFIG_FILE:-/opt/frigate/config/config.yml}"
VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0

record_error() { log_error "$1"; ((VALIDATION_ERRORS+=1)); }
record_warn() { log_warn "$1"; ((VALIDATION_WARNINGS+=1)); }

detect_container_ffmpeg() {
  pct exec "${FRIGATE_CT_ID}" -- docker exec frigate sh -c '
    if command -v ffmpeg >/dev/null 2>&1; then
      command -v ffmpeg
      exit 0
    fi

    for candidate in /usr/lib/ffmpeg/*/bin/ffmpeg /usr/lib/btbn-ffmpeg/bin/ffmpeg; do
      if [ -x "${candidate}" ]; then
        printf "%s\n" "${candidate}"
        exit 0
      fi
    done

    exit 1
  ' 2>/dev/null || true
}

log_info "=========================================="
log_info "STEP 10J - FRIGATE INTEL GPU VALIDATION"
log_info "=========================================="

if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

for cmd in pct grep awk; do
  if command -v "${cmd}" >/dev/null 2>&1; then
    log_info "Host command found: ${cmd}"
  else
    record_error "Required host command not found: ${cmd}"
  fi
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Missing required host commands"
  exit 1
fi

if ! pct status "${FRIGATE_CT_ID}" 2>/dev/null | grep -q 'status: running'; then
  log_error "CT ${FRIGATE_CT_ID} is not running"
  exit 1
fi
log_info "CT ${FRIGATE_CT_ID} is running"

if pct exec "${FRIGATE_CT_ID}" -- bash -c 'command -v docker >/dev/null 2>&1'; then
  log_info "Docker is available inside CT ${FRIGATE_CT_ID}"
else
  log_error "Docker is not available inside CT ${FRIGATE_CT_ID}"
  exit 1
fi

log_info "Checking Frigate VAAPI configuration..."
if pct exec "${FRIGATE_CT_ID}" -- test -f "${FRIGATE_CONFIG_FILE}"; then
  log_info "Frigate config file exists"
else
  log_error "Frigate config file does not exist: ${FRIGATE_CONFIG_FILE}"
  exit 1
fi

if pct exec "${FRIGATE_CT_ID}" -- grep -qE '^[[:space:]]+hwaccel_args:[[:space:]]+preset-vaapi[[:space:]]*$' "${FRIGATE_CONFIG_FILE}"; then
  log_info "Frigate config requests VAAPI hardware acceleration"
else
  record_error "Frigate config does not set ffmpeg.hwaccel_args: preset-vaapi"
fi

if pct exec "${FRIGATE_CT_ID}" -- grep -qE '^[[:space:]]+intel_gpu_stats:[[:space:]]+true[[:space:]]*$' "${FRIGATE_CONFIG_FILE}"; then
  log_info "Frigate config enables Intel GPU telemetry"
else
  record_warn "Frigate config does not explicitly enable telemetry.stats.intel_gpu_stats"
fi

log_info "Validating Docker Compose file and GPU device mapping..."
if pct exec "${FRIGATE_CT_ID}" -- bash -c "cd '${FRIGATE_APP_DIR}' && docker compose config >/dev/null"; then
  log_info "Docker Compose config is valid"
else
  record_error "Docker Compose config is not valid"
fi

if pct exec "${FRIGATE_CT_ID}" -- bash -c "cd '${FRIGATE_APP_DIR}' && docker compose config | grep -qE '/dev/dri|renderD128'"; then
  log_info "Docker Compose maps an Intel GPU render device"
else
  record_error "Docker Compose does not map /dev/dri or renderD128 into Frigate"
fi

log_info "Checking Intel GPU device visibility..."
if pct exec "${FRIGATE_CT_ID}" -- test -d /dev/dri; then
  log_info "/dev/dri is visible inside CT ${FRIGATE_CT_ID}"
else
  record_error "/dev/dri is not visible inside CT ${FRIGATE_CT_ID}"
fi

if pct exec "${FRIGATE_CT_ID}" -- test -c /dev/dri/renderD128; then
  log_info "/dev/dri/renderD128 is a character device inside CT ${FRIGATE_CT_ID}"
else
  record_error "/dev/dri/renderD128 is not a character device inside CT ${FRIGATE_CT_ID}"
fi

if pct exec "${FRIGATE_CT_ID}" -- test -r /dev/dri/renderD128 && pct exec "${FRIGATE_CT_ID}" -- test -w /dev/dri/renderD128; then
  log_info "/dev/dri/renderD128 is readable and writable inside CT ${FRIGATE_CT_ID}"
else
  record_error "/dev/dri/renderD128 is not readable and writable inside CT ${FRIGATE_CT_ID}"
fi

log_info "Checking Frigate container state..."
if pct exec "${FRIGATE_CT_ID}" -- docker ps --format '{{.Names}}' | grep -qx 'frigate'; then
  log_info "Frigate container is running"
else
  record_error "Frigate container is not running"
fi

if pct exec "${FRIGATE_CT_ID}" -- docker exec frigate test -d /dev/dri; then
  log_info "/dev/dri is visible inside the Frigate container"
else
  record_error "/dev/dri is not visible inside the Frigate container"
fi

if pct exec "${FRIGATE_CT_ID}" -- docker exec frigate test -c /dev/dri/renderD128; then
  log_info "/dev/dri/renderD128 is a character device inside the Frigate container"
else
  record_error "/dev/dri/renderD128 is not a character device inside the Frigate container"
fi

if pct exec "${FRIGATE_CT_ID}" -- docker exec frigate test -r /dev/dri/renderD128 \
  && pct exec "${FRIGATE_CT_ID}" -- docker exec frigate test -w /dev/dri/renderD128; then
  log_info "/dev/dri/renderD128 is readable and writable inside the Frigate container"
else
  record_error "/dev/dri/renderD128 is not readable and writable inside the Frigate container"
fi

log_info "Checking FFmpeg VAAPI support inside the Frigate container..."
CONTAINER_FFMPEG="$(detect_container_ffmpeg)"

if [[ -n "${CONTAINER_FFMPEG}" ]]; then
  log_info "FFmpeg is available inside the Frigate container: ${CONTAINER_FFMPEG}"
else
  record_error "FFmpeg is not available inside the Frigate container"
fi

if [[ -n "${CONTAINER_FFMPEG}" ]] \
  && pct exec "${FRIGATE_CT_ID}" -- docker exec frigate "${CONTAINER_FFMPEG}" -hide_banner -hwaccels 2>/dev/null | grep -q '^vaapi$'; then
    log_info "FFmpeg reports VAAPI hardware acceleration support"
else
  record_error "FFmpeg does not report VAAPI hardware acceleration support"
fi

if [[ -n "${CONTAINER_FFMPEG}" ]] \
  && pct exec "${FRIGATE_CT_ID}" -- docker exec frigate "${CONTAINER_FFMPEG}" \
  -hide_banner \
  -loglevel error \
  -init_hw_device vaapi=va:/dev/dri/renderD128 \
  -f lavfi \
  -i testsrc2=size=128x128:rate=1 \
  -frames:v 1 \
  -f null - >/dev/null 2>&1; then
    log_info "FFmpeg can initialize VAAPI using /dev/dri/renderD128"
else
  record_error "FFmpeg could not initialize VAAPI using /dev/dri/renderD128"
fi

FRIGATE_STARTED_AT="$(
  pct exec "${FRIGATE_CT_ID}" -- docker inspect --format '{{.State.StartedAt}}' frigate 2>/dev/null || true
)"

if [[ -n "${FRIGATE_STARTED_AT}" ]]; then
  FRIGATE_LOGS="$(pct exec "${FRIGATE_CT_ID}" -- docker logs --since "${FRIGATE_STARTED_AT}" frigate 2>&1 || true)"
else
  record_warn "Could not determine Frigate container start time; checking last 300 log lines"
  FRIGATE_LOGS="$(pct exec "${FRIGATE_CT_ID}" -- docker logs --tail 300 frigate 2>&1 || true)"
fi

log_info "Checking Frigate logs for VAAPI failures..."
if grep -qiE 'vaapi.*(error|failed|unable|invalid|permission denied)|hwaccel.*(error|failed|unable|invalid)|renderD128.*(error|failed|unable|permission denied)|No VA display found|Failed to initialise VAAPI|Device creation failed' <<< "${FRIGATE_LOGS}"; then
  record_error "Frigate logs contain VAAPI/hardware acceleration failures"
else
  log_info "No VAAPI/hardware acceleration failures found in checked Frigate logs"
fi

log_info "Checking live FFmpeg process arguments..."
FFMPEG_PROCESSES="$(
  pct exec "${FRIGATE_CT_ID}" -- docker exec frigate sh -c "ps -eo args | grep '[f]fmpeg'" 2>/dev/null || true
)"

if [[ -z "${FFMPEG_PROCESSES}" ]]; then
  record_warn "No live FFmpeg processes found; open a camera live view or wait for recording/detect to start, then rerun"
elif grep -qiE '(-hwaccel[ =]vaapi|preset-vaapi|/dev/dri/renderD128|vaapi)' <<< "${FFMPEG_PROCESSES}"; then
  log_info "Live FFmpeg process arguments reference VAAPI/renderD128"
else
  record_warn "Live FFmpeg processes were found, but their arguments do not visibly reference VAAPI/renderD128"
fi

log_info "Checking Frigate GPU telemetry..."
GPU_STATS_RESULT="$(
  pct exec "${FRIGATE_CT_ID}" -- docker exec frigate python3 -c '
import json
import urllib.request
data = json.load(urllib.request.urlopen("http://127.0.0.1:5000/api/stats", timeout=5))
gpu_usages = data.get("gpu_usages", {})
if not isinstance(gpu_usages, dict) or not gpu_usages:
    print("MISSING")
elif "error-gpu" in gpu_usages:
    print("ERROR")
else:
    name, values = next(iter(gpu_usages.items()))
    gpu = values.get("gpu") if isinstance(values, dict) else None
    mem = values.get("mem") if isinstance(values, dict) else None
    if gpu in ("", None) and mem in ("", None):
        print(f"EMPTY|{name}")
    else:
        print(f"FOUND|{name}|gpu={gpu}|mem={mem}")
' 2>/dev/null || true
)"

case "${GPU_STATS_RESULT}" in
  FOUND\|*)
    log_info "Frigate reports GPU telemetry: ${GPU_STATS_RESULT#FOUND|}"
    ;;
  EMPTY\|*)
    record_warn "Frigate GPU telemetry source is present (${GPU_STATS_RESULT#EMPTY|}), but usage values are currently empty"
    ;;
  ERROR)
    record_error "Frigate reports error-gpu in /api/stats; Intel GPU telemetry is failing"
    ;;
  *)
    record_warn "Frigate /api/stats does not report GPU telemetry"
    ;;
esac

if pct exec "${FRIGATE_CT_ID}" -- docker exec frigate sh -c 'command -v intel_gpu_top >/dev/null 2>&1'; then
  log_info "intel_gpu_top is available inside the Frigate container"
else
  record_warn "intel_gpu_top is not available inside the Frigate container; Frigate UI may not show Intel GPU usage"
fi

log_info "=========================================="
log_info "INTEL GPU VALIDATION SUMMARY"
log_info "=========================================="
log_info "Validation warnings: ${VALIDATION_WARNINGS}"
log_info "Validation errors: ${VALIDATION_ERRORS}"

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Frigate Intel GPU validation failed"
  exit 1
elif [[ "${VALIDATION_WARNINGS}" -gt 0 ]]; then
  log_warn "Frigate Intel GPU validation completed with warnings"
  exit 0
fi

log_info "Frigate Intel GPU validation completed successfully"
