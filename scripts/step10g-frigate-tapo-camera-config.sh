#!/usr/bin/env bash
# Configure either supported Tapo camera profile in Frigate.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      cat <<EOF
Usage: TAPO_CAMERA_PROFILE=c200|c320ws $0 [--dry-run]

Render and configure one Tapo camera block in Frigate. The default mode writes
the config after creating a backup; --dry-run performs preflight and renders
the change without making a backup or writing any files.
EOF
      exit 0
      ;;
    *) printf 'Unknown argument: %s\n' "${arg}" >&2; exit 2 ;;
  esac
done

if [[ "${DRY_RUN}" -eq 1 ]]; then
  LOG_FILE=/dev/null
fi

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
    CAMERA_DETECT_FPS="${TAPO_C200_DETECT_FPS:-${TAPO_CAMERA_DETECT_FPS:-5}}"
    ;;
  c320ws)
    CAMERA_NAME="${TAPO_C320WS_NAME:-tplink_c320ws_1}"
    CAMERA_IP="${TAPO_C320WS_IP:-}"
    CAMERA_USERNAME="${TAPO_C320WS_USERNAME:-}"
    CAMERA_PASSWORD="${TAPO_C320WS_PASSWORD:-}"
    CAMERA_DETECT_WIDTH="${TAPO_C320WS_DETECT_WIDTH:-640}"
    CAMERA_DETECT_HEIGHT="${TAPO_C320WS_DETECT_HEIGHT:-360}"
    CAMERA_DETECT_FPS="${TAPO_C320WS_DETECT_FPS:-${TAPO_CAMERA_DETECT_FPS:-5}}"
    ;;
  *)
    log_error "Unsupported TAPO_CAMERA_PROFILE: ${TAPO_CAMERA_PROFILE} (use c200 or c320ws)"
    exit 1
    ;;
esac

CAMERA_RTSP_PORT="${TAPO_CAMERA_RTSP_PORT:-554}"
CAMERA_RECORD_STREAM_PATH="${TAPO_CAMERA_RECORD_STREAM_PATH:-/stream1}"
CAMERA_DETECT_STREAM_PATH="${TAPO_CAMERA_DETECT_STREAM_PATH:-/stream2}"
CAMERA_ONVIF_PORT="${TAPO_CAMERA_ONVIF_PORT:-2020}"
CAMERA_CONFIG_HELPER="${PROJECT_ROOT}/lib/frigate-camera-config.py"
VALIDATION_ERRORS=0

record_error() {
  log_error "$1"
  ((VALIDATION_ERRORS+=1))
}

if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

for cmd in pct date python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    record_error "Required host command not found: ${cmd}"
  fi
done
if [[ ! "${FRIGATE_CT_ID}" =~ ^[0-9]+$ ]]; then
  record_error "Docker CT ID must be numeric"
fi
[[ -f "${CAMERA_CONFIG_HELPER}" ]] || record_error "Missing helper: ${CAMERA_CONFIG_HELPER}"
if [[ -z "${CAMERA_IP}" || -z "${CAMERA_USERNAME}" || -z "${CAMERA_PASSWORD}" ]]; then
  record_error "Camera IP, username, and password are required for profile ${TAPO_CAMERA_PROFILE}"
fi
if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Cannot continue until preflight inputs are corrected"
  exit 1
fi

for ct_command in config status; do
  if [[ "${ct_command}" == config ]]; then
    if pct config "${FRIGATE_CT_ID}" >/dev/null 2>&1; then
      log_info "CT ${FRIGATE_CT_ID} exists"
    else
      record_error "Could not read config for CT ${FRIGATE_CT_ID}"
    fi
  else
    if ! CT_STATUS="$(pct status "${FRIGATE_CT_ID}" 2>&1)"; then
      record_error "Could not query status for CT ${FRIGATE_CT_ID}: ${CT_STATUS}"
    elif [[ "${CT_STATUS}" == *"status: running"* ]]; then
      log_info "CT ${FRIGATE_CT_ID} is running"
    else
      record_error "CT ${FRIGATE_CT_ID} is not running"
    fi
  fi
done
if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Cannot continue until the Frigate CT is ready"
  exit 1
fi

if ! pct exec "${FRIGATE_CT_ID}" -- test -f "${FRIGATE_CONFIG_FILE}"; then
  log_error "Frigate config file does not exist: ${FRIGATE_CONFIG_FILE}"
  exit 1
fi
if ! pct exec "${FRIGATE_CT_ID}" -- bash -c \
  'cd -- "$1" && docker compose version >/dev/null && docker compose config >/dev/null' \
  bash "${FRIGATE_APP_DIR}"; then
  log_error "Docker Compose is unavailable or its current configuration is invalid"
  exit 1
fi

CAMERA_CONFIG_HELPER_TEXT="$(<"${CAMERA_CONFIG_HELPER}")"
run_camera_config() {
  local mode="$1"
  local -a mode_args=()
  [[ "${mode}" != "--dry-run" ]] || mode_args=(--dry-run)
  printf '%s\0' \
    "${CAMERA_NAME}" "${CAMERA_IP}" "${CAMERA_USERNAME}" "${CAMERA_PASSWORD}" \
    "${CAMERA_RTSP_PORT}" "${CAMERA_RECORD_STREAM_PATH}" "${CAMERA_DETECT_STREAM_PATH}" \
    "${CAMERA_DETECT_WIDTH}" "${CAMERA_DETECT_HEIGHT}" "${CAMERA_DETECT_FPS}" \
    "${CAMERA_ONVIF_PORT}" \
    | pct exec "${FRIGATE_CT_ID}" -- python3 -c "${CAMERA_CONFIG_HELPER_TEXT}" \
      "${FRIGATE_CONFIG_FILE}" "${mode_args[@]}"
}

log_info "Checking camera inputs and rendering a secret-safe preview..."
if ! PREVIEW_RESULT="$(run_camera_config --dry-run 2>&1)"; then
  log_error "Camera config validation failed: ${PREVIEW_RESULT}"
  exit 1
fi
log_info "Profile ${TAPO_CAMERA_PROFILE}: ${CAMERA_NAME} at ${CAMERA_IP}"
log_info "Record ${CAMERA_RECORD_STREAM_PATH}; detect ${CAMERA_DETECT_STREAM_PATH} at ${CAMERA_DETECT_WIDTH}x${CAMERA_DETECT_HEIGHT}@${CAMERA_DETECT_FPS} FPS"

if [[ "${PREVIEW_RESULT}" == "UNCHANGED" ]]; then
  log_info "Camera config already matches; no backup or write is needed"
  exit 0
fi
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "${PREVIEW_RESULT}"
  log_info "No backup, configuration write, or service restart was performed"
  exit 0
fi

BACKUP_FILE="${FRIGATE_CONFIG_FILE}.bak-$(date +%Y%m%d%H%M%S%N)"
if pct exec "${FRIGATE_CT_ID}" -- test ! -e "${BACKUP_FILE}"; then
  :
else
  log_error "Refusing to overwrite existing config backup: ${BACKUP_FILE}"
  exit 1
fi
log_info "Creating Frigate config backup: ${BACKUP_FILE}"
pct exec "${FRIGATE_CT_ID}" -- cp -p -- "${FRIGATE_CONFIG_FILE}" "${BACKUP_FILE}"

restore_config() {
  if pct exec "${FRIGATE_CT_ID}" -- cp -p -- "${BACKUP_FILE}" "${FRIGATE_CONFIG_FILE}"; then
    log_warn "Frigate config was rolled back from ${BACKUP_FILE}"
  else
    log_error "Automatic rollback failed; restore manually from ${BACKUP_FILE}"
  fi
}

log_info "Writing camera config atomically (credentials are passed over stdin)..."
if ! WRITE_RESULT="$(run_camera_config apply 2>&1)" || [[ "${WRITE_RESULT}" != "CHANGED" ]]; then
  log_error "Camera config write failed; restoring the backup"
  restore_config
  exit 1
fi

log_info "Validating the updated Frigate configuration..."
if ! VERIFY_RESULT="$(run_camera_config --dry-run 2>&1)" || [[ "${VERIFY_RESULT}" != "UNCHANGED" ]] \
  || ! pct exec "${FRIGATE_CT_ID}" -- bash -c \
    'cd -- "$1" && docker compose config >/dev/null' bash "${FRIGATE_APP_DIR}"; then
  log_error "Updated config validation failed; restoring the backup"
  restore_config
  exit 1
fi

log_info "Frigate camera config updated and validated successfully"
log_info "Backup retained at: ${BACKUP_FILE}"
log_info "Restart Frigate with scripts/step10e-frigate-restart.sh"
log_info "Then validate with scripts/step10h-frigate-camera-validation.sh"
