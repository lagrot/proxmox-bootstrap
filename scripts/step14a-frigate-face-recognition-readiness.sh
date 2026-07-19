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
log_info "STEP 14A - FRIGATE FACE RECOGNITION READINESS"
log_info "========================================================"

FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
FRIGATE_INTERNAL_PORT="${FRIGATE_INTERNAL_PORT:-5000}"
CAMERA_NAMES=(
  "${TAPO_C200_NAME:-${TAPO_CAMERA_NAME:-tplink_c200_1}}"
  "${TAPO_C320WS_NAME:-tplink_c320ws_1}"
)
CONFIG_FILE="/tmp/frigate-face-readiness-config.json"
STATS_FILE="/tmp/frigate-face-readiness-stats.json"

READINESS_ERRORS=0
READINESS_WARNINGS=0

record_error() {
  log_error "$1"
  ((READINESS_ERRORS+=1))
}

record_warning() {
  log_warn "$1"
  ((READINESS_WARNINGS+=1))
}

if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

for cmd in pct grep awk; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Required command not found: ${cmd}"
    exit 1
  fi
done

if ! pct status "${FRIGATE_CT_ID}" 2>/dev/null | grep -q "status: running"; then
  log_error "CT ${FRIGATE_CT_ID} is not running"
  exit 1
fi

cleanup() {
  pct exec "${FRIGATE_CT_ID}" -- rm -f \
    "${CONFIG_FILE}" "${STATS_FILE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log_info "Checking Frigate container and pinned version..."
if ! pct exec "${FRIGATE_CT_ID}" -- docker ps --format '{{.Names}}' | grep -qx frigate; then
  record_error "Frigate container is not running"
else
  HEALTH="$(pct exec "${FRIGATE_CT_ID}" -- docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' frigate 2>/dev/null || true)"
  IMAGE="$(pct exec "${FRIGATE_CT_ID}" -- docker inspect \
    --format '{{.Config.Image}}' frigate 2>/dev/null || true)"
  if [[ "${HEALTH}" == "healthy" ]]; then
    log_info "Frigate container is healthy"
  else
    record_error "Unexpected Frigate health: ${HEALTH:-unknown}"
  fi
  log_info "Frigate image: ${IMAGE:-unknown}"
fi

VERSION="$(pct exec "${FRIGATE_CT_ID}" -- curl -fsS --max-time 10 \
  "http://127.0.0.1:${FRIGATE_INTERNAL_PORT}/api/version" 2>/dev/null || true)"
if [[ -n "${VERSION}" ]]; then
  log_info "Frigate API version: ${VERSION}"
else
  record_error "Could not read the Frigate API version"
fi

log_info "Checking CPU requirements..."
CPU_MODEL="$(pct exec "${FRIGATE_CT_ID}" -- awk -F: \
  '/^model name/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }' /proc/cpuinfo)"
CPU_FLAGS="$(pct exec "${FRIGATE_CT_ID}" -- awk -F: \
  '/^flags/ { print $2; exit }' /proc/cpuinfo)"
log_info "CPU: ${CPU_MODEL:-unknown}"
for flag in avx avx2; do
  if grep -qw "${flag}" <<< "${CPU_FLAGS}"; then
    log_info "CPU instruction available: ${flag}"
  else
    record_error "Required CPU instruction is missing: ${flag}"
  fi
done

CT_CONFIG="$(pct config "${FRIGATE_CT_ID}")"
CT_CORES="$(awk '/^cores:/ {print $2}' <<< "${CT_CONFIG}")"
CT_MEMORY_MB="$(awk '/^memory:/ {print $2}' <<< "${CT_CONFIG}")"
log_info "CT resources: ${CT_CORES:-unknown} cores, ${CT_MEMORY_MB:-unknown} MiB RAM"

log_info "Checking Intel GPU availability for an optional large-model test..."
if pct exec "${FRIGATE_CT_ID}" -- docker exec frigate test -r /dev/dri/renderD128; then
  log_info "Intel render device is readable inside Frigate"
else
  record_warning "Intel render device is unavailable; only the CPU small-model path is ready"
fi

log_info "Reading selected effective config and stats through the internal API..."
if ! pct exec "${FRIGATE_CT_ID}" -- sh -c \
  "umask 077; curl -fsS --max-time 15 'http://127.0.0.1:${FRIGATE_INTERNAL_PORT}/api/config' > '${CONFIG_FILE}'"; then
  record_error "Could not retrieve effective Frigate config"
fi
if ! pct exec "${FRIGATE_CT_ID}" -- sh -c \
  "umask 077; curl -fsS --max-time 15 'http://127.0.0.1:${FRIGATE_INTERNAL_PORT}/api/stats' > '${STATS_FILE}'"; then
  record_error "Could not retrieve Frigate stats"
fi

if (( READINESS_ERRORS == 0 )); then
  ASSESSMENT_OUTPUT="$(pct exec "${FRIGATE_CT_ID}" -- python3 - \
    "${CONFIG_FILE}" "${STATS_FILE}" "${CAMERA_NAMES[@]}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    stats = json.load(handle)
cameras = sys.argv[3:]

def emit(level, message):
    print(f"{level}|{message}")

face = config.get("face_recognition")
if not isinstance(face, dict):
    emit("ERROR", "Effective config does not expose native face recognition support")
else:
    emit("INFO", f"Face recognition enabled: {str(bool(face.get('enabled'))).lower()}")
    emit("INFO", f"Configured model size: {face.get('model_size', 'unknown')}")
    emit(
        "INFO",
        "Current thresholds: "
        f"detection={face.get('detection_threshold', 'unknown')}, "
        f"recognition={face.get('recognition_threshold', 'unknown')}, "
        f"unknown={face.get('unknown_score', 'unknown')}, "
        f"min_area={face.get('min_area', 'unknown')}, "
        f"min_faces={face.get('min_faces', 'unknown')}",
    )
    if face.get("enabled"):
        emit("WARN", "Face recognition is already enabled; Step 14A expected a disabled baseline")

configured_cameras = config.get("cameras", {})
camera_stats = stats.get("cameras", {})
for name in cameras:
    camera = configured_cameras.get(name)
    if camera is None:
        emit("ERROR", f"Required camera is missing: {name}")
        continue
    detect = camera.get("detect", {})
    width = int(detect.get("width", 0) or 0)
    height = int(detect.get("height", 0) or 0)
    fps = float(detect.get("fps", 0) or 0)
    emit("INFO", f"{name} detect stream: {width}x{height} at {fps:g} FPS")
    if not detect.get("enabled"):
        emit("ERROR", f"{name} object detection is disabled")
    if width * height <= 640 * 360:
        emit(
            "WARN",
            f"{name} detect resolution may only recognize clear, close faces; "
            "test quality before changing resolution",
        )
    runtime = camera_stats.get(name, {})
    process_fps = float(runtime.get("process_fps", 0) or 0)
    skipped_fps = float(runtime.get("skipped_fps", 0) or 0)
    emit("INFO", f"{name} runtime: process_fps={process_fps:g}, skipped_fps={skipped_fps:g}")
    if skipped_fps > 0.5:
        emit("WARN", f"{name} is skipping more than 0.5 FPS before face recognition")

detectors = stats.get("detectors", {})
coral = detectors.get("coral")
if coral is None:
    emit("ERROR", "Live Coral detector stats are missing")
else:
    emit("INFO", f"Coral inference baseline: {float(coral.get('inference_speed', 0)):.2f} ms")

gpu = stats.get("gpu_usages", {}).get("intel-vaapi", {})
if gpu:
    emit("INFO", f"Intel GPU baseline: gpu={gpu.get('gpu', 'unknown')}, memory={gpu.get('mem', 'unknown')}")
else:
    emit("WARN", "Intel GPU telemetry is unavailable")

full_system = stats.get("cpu_usages", {}).get("frigate.full_system", {})
if full_system:
    emit(
        "INFO",
        f"Frigate baseline: cpu={full_system.get('cpu', 'unknown')}%, "
        f"memory={full_system.get('mem', 'unknown')}%",
    )

embeddings = stats.get("embeddings", {})
emit("INFO", "Embedding/recognition stats are idle" if not embeddings else "Embedding stats are already active")

storage = stats.get("service", {}).get("storage", {}).get("/media/frigate/clips", {})
if storage:
    emit(
        "INFO",
        f"Media storage baseline: used={storage.get('used', 'unknown')} MiB, "
        f"free={storage.get('free', 'unknown')} MiB",
    )
PY
)"

  while IFS='|' read -r level message; do
    case "${level}" in
      INFO) log_info "${message}" ;;
      WARN) record_warning "${message}" ;;
      ERROR) record_error "${message}" ;;
      *) record_error "Unexpected readiness output" ;;
    esac
  done <<< "${ASSESSMENT_OUTPUT}"
fi

log_info "Privacy gate: enrol only consenting household members"
log_info "Privacy gate: keep face processing local and do not auto-enrol visitors"
log_info "Pilot gate: start with one camera and the small CPU model"
log_info "Pilot gate: validate accuracy and resource use before changing detect resolution"
log_info "========================================================"
log_info "FACE RECOGNITION READINESS SUMMARY"
log_info "========================================================"
log_info "Readiness warnings: ${READINESS_WARNINGS}"
log_info "Readiness errors: ${READINESS_ERRORS}"

if (( READINESS_ERRORS > 0 )); then
  log_error "Face-recognition readiness assessment failed"
  exit 1
fi

if (( READINESS_WARNINGS > 0 )); then
  log_warn "Ready for a controlled pilot with the documented warnings"
else
  log_info "Ready for a controlled face-recognition pilot"
fi
log_info "No Frigate, camera, Home Assistant, or face-library data was changed"
