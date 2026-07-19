#!/usr/bin/env bash
# Configure either supported Tapo camera profile in Frigate.
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

log_info "=============================================="
log_info "STEP 10G - FRIGATE TAPO CAMERA CONFIG"
log_info "=============================================="

FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
FRIGATE_APP_DIR="${FRIGATE_APP_DIR:-/opt/frigate}"
FRIGATE_CONFIG_FILE="${FRIGATE_CONFIG_FILE:-/opt/frigate/config/config.yml}"

TAPO_CAMERA_PROFILE="${TAPO_CAMERA_PROFILE:-c200}"

case "${TAPO_CAMERA_PROFILE}" in
  c200)
    CAMERA_NAME="${TAPO_C200_NAME:-${TAPO_CAMERA_NAME:-tplink_c200_1}}"
    CAMERA_IP="${TAPO_C200_IP:-${TAPO_CAMERA_IP:-}}"
    CAMERA_USERNAME="${TAPO_C200_USERNAME:-${TAPO_CAMERA_USERNAME:-}}"
    CAMERA_PASSWORD="${TAPO_C200_PASSWORD:-${TAPO_CAMERA_PASSWORD:-}}"
    CAMERA_DETECT_WIDTH="${TAPO_C200_DETECT_WIDTH:-640}"
    CAMERA_DETECT_HEIGHT="${TAPO_C200_DETECT_HEIGHT:-360}"
    ;;
  c320ws)
    CAMERA_NAME="${TAPO_C320WS_NAME:-tplink_c320ws_1}"
    CAMERA_IP="${TAPO_C320WS_IP:-}"
    CAMERA_USERNAME="${TAPO_C320WS_USERNAME:-}"
    CAMERA_PASSWORD="${TAPO_C320WS_PASSWORD:-}"
    CAMERA_DETECT_WIDTH="${TAPO_C320WS_DETECT_WIDTH:-640}"
    CAMERA_DETECT_HEIGHT="${TAPO_C320WS_DETECT_HEIGHT:-360}"
    ;;
  *)
    log_error "Unsupported TAPO_CAMERA_PROFILE: ${TAPO_CAMERA_PROFILE} (use c200 or c320ws)"
    exit 1
    ;;
esac

CAMERA_RTSP_PORT="${TAPO_CAMERA_RTSP_PORT:-554}"
CAMERA_RECORD_STREAM_PATH="${TAPO_CAMERA_RECORD_STREAM_PATH:-/stream1}"
CAMERA_DETECT_STREAM_PATH="${TAPO_CAMERA_DETECT_STREAM_PATH:-/stream2}"
CAMERA_DETECT_FPS="${TAPO_CAMERA_DETECT_FPS:-5}"
CAMERA_ONVIF_PORT="${TAPO_CAMERA_ONVIF_PORT:-2020}"

VALIDATION_ERRORS=0

record_error() {
  log_error "$1"
  ((VALIDATION_ERRORS+=1))
}

check_host_command() {
  local cmd="$1"

  if command -v "${cmd}" >/dev/null 2>&1; then
    log_info "Host command found: ${cmd}"
  else
    record_error "Required host command not found: ${cmd}"
  fi
}

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required host commands..."
for cmd in pct awk grep date; do
  check_host_command "${cmd}"
done

if [[ -z "${CAMERA_IP}" ]]; then
  record_error "Camera IP is required for profile ${TAPO_CAMERA_PROFILE}"
fi

if [[ -z "${CAMERA_USERNAME}" ]]; then
  record_error "Camera username is required for profile ${TAPO_CAMERA_PROFILE}"
fi

if [[ -z "${CAMERA_PASSWORD}" ]]; then
  record_error "Camera password is required for profile ${TAPO_CAMERA_PROFILE}"
fi

if [[ "${CAMERA_NAME}" =~ [^a-zA-Z0-9_] ]]; then
  record_error "TAPO_CAMERA_NAME must contain only letters, numbers, and underscores"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Cannot continue until required inputs are provided"
  log_info "Example:"
  log_info "Populate the TAPO_C200_* or TAPO_C320WS_* values in config/local.conf"
  exit 1
fi

log_info "Checking CT ${FRIGATE_CT_ID}..."
if pct config "${FRIGATE_CT_ID}" >/dev/null 2>&1; then
  log_info "CT ${FRIGATE_CT_ID} exists"
else
  log_error "CT ${FRIGATE_CT_ID} does not exist"
  exit 1
fi

if pct status "${FRIGATE_CT_ID}" 2>/dev/null | grep -q "status: running"; then
  log_info "CT ${FRIGATE_CT_ID} is running"
else
  log_error "CT ${FRIGATE_CT_ID} is not running"
  exit 1
fi

log_info "Checking Frigate config file..."
if ! pct exec "${FRIGATE_CT_ID}" -- test -f "${FRIGATE_CONFIG_FILE}"; then
  log_error "Frigate config file does not exist: ${FRIGATE_CONFIG_FILE}"
  exit 1
fi

BACKUP_FILE="${FRIGATE_CONFIG_FILE}.bak-$(date +%Y%m%d%H%M%S)"
log_info "Creating Frigate config backup: ${BACKUP_FILE}"
pct exec "${FRIGATE_CT_ID}" -- cp "${FRIGATE_CONFIG_FILE}" "${BACKUP_FILE}"

log_info "Writing camera '${CAMERA_NAME}' into Frigate config..."
pct exec "${FRIGATE_CT_ID}" -- python3 - \
  "${FRIGATE_CONFIG_FILE}" \
  "${CAMERA_NAME}" \
  "${CAMERA_IP}" \
  "${CAMERA_USERNAME}" \
  "${CAMERA_PASSWORD}" \
  "${CAMERA_RTSP_PORT}" \
  "${CAMERA_RECORD_STREAM_PATH}" \
  "${CAMERA_DETECT_STREAM_PATH}" \
  "${CAMERA_DETECT_WIDTH}" \
  "${CAMERA_DETECT_HEIGHT}" \
  "${CAMERA_DETECT_FPS}" \
  "${CAMERA_ONVIF_PORT}" <<'PY'
import pathlib
import json
import re
import sys
from urllib.parse import quote

config_path = pathlib.Path(sys.argv[1])
camera_name = sys.argv[2]
camera_ip = sys.argv[3]
camera_username_raw = sys.argv[4]
camera_password_raw = sys.argv[5]
camera_username = quote(camera_username_raw, safe="")
camera_password = quote(camera_password_raw, safe="")
camera_rtsp_port = sys.argv[6]
camera_record_stream_path = sys.argv[7]
camera_detect_stream_path = sys.argv[8]
camera_detect_width = sys.argv[9]
camera_detect_height = sys.argv[10]
camera_detect_fps = sys.argv[11]
camera_onvif_port = sys.argv[12]

lines = config_path.read_text().splitlines()
record_stream_path = camera_record_stream_path if camera_record_stream_path.startswith("/") else f"/{camera_record_stream_path}"
detect_stream_path = camera_detect_stream_path if camera_detect_stream_path.startswith("/") else f"/{camera_detect_stream_path}"
record_rtsp_url = f"rtsp://{camera_username}:{camera_password}@{camera_ip}:{camera_rtsp_port}{record_stream_path}"
detect_rtsp_url = f"rtsp://{camera_username}:{camera_password}@{camera_ip}:{camera_rtsp_port}{detect_stream_path}"

camera_block = [
    f"  {camera_name}:",
    "    enabled: true",
    "    ffmpeg:",
    "      inputs:",
    f"        - path: {record_rtsp_url}",
    "          input_args: preset-rtsp-generic",
    "          roles:",
    "            - record",
    f"        - path: {detect_rtsp_url}",
    "          input_args: preset-rtsp-generic",
    "          roles:",
    "            - detect",
    "    onvif:",
    f"      host: {camera_ip}",
    f"      port: {camera_onvif_port}",
    f"      user: {json.dumps(camera_username_raw)}",
    f"      password: {json.dumps(camera_password_raw)}",
    "    detect:",
    "      enabled: true",
    f"      width: {camera_detect_width}",
    f"      height: {camera_detect_height}",
    f"      fps: {camera_detect_fps}",
    "    record:",
    "      enabled: true",
    "    snapshots:",
    "      enabled: true",
]

camera_key = f"  {camera_name}:"
cameras_index = None
section_end = len(lines)

for idx, line in enumerate(lines):
    if re.match(r"^cameras:\s*(\{\})?\s*$", line):
        cameras_index = idx
        break

if cameras_index is None:
    insert_at = len(lines)
    for idx, line in enumerate(lines):
        if line.startswith("version:"):
            insert_at = idx
            break
    rendered = lines[:insert_at] + ["cameras:"] + camera_block + lines[insert_at:]
    config_path.write_text("\n".join(rendered).rstrip() + "\n")
    raise SystemExit(0)

line = lines[cameras_index]
if "{}" in line:
    rendered = lines[:cameras_index] + ["cameras:"] + camera_block + lines[cameras_index + 1:]
    config_path.write_text("\n".join(rendered).rstrip() + "\n")
    raise SystemExit(0)

for idx in range(cameras_index + 1, len(lines)):
    current = lines[idx]
    if current and not current.startswith(" "):
      section_end = idx
      break

camera_start = None
camera_end = section_end

for idx in range(cameras_index + 1, section_end):
    if lines[idx] == camera_key:
        camera_start = idx
        break

if camera_start is not None:
    for idx in range(camera_start + 1, section_end):
        if re.match(r"^  [A-Za-z0-9_]+:$", lines[idx]):
            camera_end = idx
            break
    rendered = lines[:camera_start] + camera_block + lines[camera_end:]
else:
    insertion = section_end
    if insertion > 0 and lines[insertion - 1] != "":
        rendered = lines[:insertion] + [""] + camera_block + lines[insertion:]
    else:
        rendered = lines[:insertion] + camera_block + lines[insertion:]

    config_path.write_text("\n".join(rendered).rstrip() + "\n")
    raise SystemExit(0)

config_path.write_text("\n".join(rendered).rstrip() + "\n")
PY

log_info "Checking rendered Frigate config contains camera settings..."
if pct exec "${FRIGATE_CT_ID}" -- grep -qxF "  ${CAMERA_NAME}:" "${FRIGATE_CONFIG_FILE}" \
  && pct exec "${FRIGATE_CT_ID}" -- grep -q "${CAMERA_IP}:${CAMERA_RTSP_PORT}" "${FRIGATE_CONFIG_FILE}"; then
  log_info "Camera settings are present for ${CAMERA_NAME}"
else
  log_error "Camera settings were not written correctly"
  exit 1
fi

log_info "Validating Docker Compose file after config update..."
pct exec "${FRIGATE_CT_ID}" -- bash -c "cd '${FRIGATE_APP_DIR}' && docker compose config >/dev/null"

log_info "Frigate camera config updated successfully"
log_info "Restart Frigate with scripts/step10e-frigate-restart.sh"
log_info "Then validate with scripts/step10h-frigate-camera-validation.sh"
