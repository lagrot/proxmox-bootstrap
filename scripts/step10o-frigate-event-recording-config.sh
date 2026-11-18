#!/usr/bin/env bash
# Configure Frigate to retain video only for tracked-object events.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--dry-run]

Configure global event-only video retention in Frigate. The default mode
creates a unique backup, writes the config atomically, and checks Docker
Compose config. --dry-run performs the same preflight and render without
creating a backup or changing files. Neither mode restarts Frigate.
EOF
      exit 0
      ;;
    *) printf 'Unknown argument: %s\n' "${arg}" >&2; exit 2 ;;
  esac
done

if [[ "${DRY_RUN}" -eq 1 ]]; then LOG_FILE=/dev/null; fi
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
FRIGATE_APP_DIR="${FRIGATE_APP_DIR:-/opt/frigate}"
FRIGATE_CONFIG_FILE="${FRIGATE_CONFIG_FILE:-/opt/frigate/config/config.yml}"
EVENT_RECORDING_DAYS="${FRIGATE_EVENT_RECORDING_DAYS:-10}"
EVENT_PRE_CAPTURE_SECONDS="${FRIGATE_EVENT_PRE_CAPTURE_SECONDS:-5}"
EVENT_POST_CAPTURE_SECONDS="${FRIGATE_EVENT_POST_CAPTURE_SECONDS:-5}"
CONFIG_HELPER="${PROJECT_ROOT}/lib/frigate-event-recording-config.py"

if [[ "${EUID}" -ne 0 ]]; then log_error "This script must be run as root"; exit 1; fi
if [[ ! "${FRIGATE_CT_ID}" =~ ^[0-9]+$ ]]; then log_error "Frigate CT ID must be numeric"; exit 1; fi
for value_name in EVENT_RECORDING_DAYS EVENT_PRE_CAPTURE_SECONDS EVENT_POST_CAPTURE_SECONDS; do
  value="${!value_name}"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    log_error "${value_name} must be a non-negative integer"; exit 1
  fi
done
if (( EVENT_RECORDING_DAYS == 0 )); then log_error "EVENT_RECORDING_DAYS must be greater than zero"; exit 1; fi
if [[ ! -f "${CONFIG_HELPER}" ]]; then log_error "Missing config helper: ${CONFIG_HELPER}"; exit 1; fi
if ! CT_STATUS="$(pct status "${FRIGATE_CT_ID}" 2>&1)"; then
  log_error "Could not query status for CT ${FRIGATE_CT_ID}: ${CT_STATUS}"; exit 1
fi
if [[ "${CT_STATUS}" != *"status: running"* ]]; then log_error "CT ${FRIGATE_CT_ID} is not running"; exit 1; fi
if ! pct exec "${FRIGATE_CT_ID}" -- test -f "${FRIGATE_CONFIG_FILE}"; then
  log_error "Frigate config file does not exist: ${FRIGATE_CONFIG_FILE}"; exit 1
fi
if ! pct exec "${FRIGATE_CT_ID}" -- bash -c \
  'cd -- "$1" && docker compose version >/dev/null && docker compose config >/dev/null' bash "${FRIGATE_APP_DIR}"; then
  log_error "Docker Compose is unavailable or current configuration is invalid"; exit 1
fi

HELPER_TEXT="$(<"${CONFIG_HELPER}")"
run_config() {
  local mode="$1"
  local -a mode_args=()
  if [[ "${mode}" == --restore ]]; then
    pct exec "${FRIGATE_CT_ID}" -- python3 -c "${HELPER_TEXT}" \
      "${FRIGATE_CONFIG_FILE}" --restore "$2"
    return
  fi
  case "${mode}" in
    --dry-run) mode_args=(--dry-run) ;;
    --backup) mode_args=(--backup "$2") ;;
  esac
  pct exec "${FRIGATE_CT_ID}" -- python3 -c "${HELPER_TEXT}" \
    "${FRIGATE_CONFIG_FILE}" "${EVENT_RECORDING_DAYS}" \
    "${EVENT_PRE_CAPTURE_SECONDS}" "${EVENT_POST_CAPTURE_SECONDS}" "${mode_args[@]}"
}

if ! PREVIEW="$(run_config --dry-run 2>&1)"; then
  log_error "Could not safely render event-recording config: ${PREVIEW}"; exit 1
fi
log_info "Policy: continuous 0 days; motion 0 days; alerts/detections ${EVENT_RECORDING_DAYS} days"
log_info "Event capture: ${EVENT_PRE_CAPTURE_SECONDS}s before and ${EVENT_POST_CAPTURE_SECONDS}s after"
if [[ "${PREVIEW}" == UNCHANGED ]]; then
  log_info "Config already matches; no backup or write is needed"; exit 0
fi
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "${PREVIEW}"
  log_info "No backup, configuration write, or service restart was performed"
  exit 0
fi

BACKUP_FILE="${FRIGATE_CONFIG_FILE}.bak-event-recording-$(date +%Y%m%d%H%M%S%N)"
if ! pct exec "${FRIGATE_CT_ID}" -- test ! -e "${BACKUP_FILE}"; then
  log_error "Refusing to overwrite existing config backup: ${BACKUP_FILE}"; exit 1
fi
log_info "Creating Frigate config backup: ${BACKUP_FILE}"

restore_config() {
  if RESTORE_RESULT="$(run_config --restore "${BACKUP_FILE}" 2>&1)" && [[ "${RESTORE_RESULT}" == RESTORED ]]; then
    log_warn "Frigate config was restored from ${BACKUP_FILE}"
  else
    log_error "Automatic restore failed (${RESTORE_RESULT}); recover manually from ${BACKUP_FILE}"
  fi
}

if ! WRITE_RESULT="$(run_config --backup "${BACKUP_FILE}" 2>&1)"; then
  log_error "Config write failed: ${WRITE_RESULT}"
  if pct exec "${FRIGATE_CT_ID}" -- test -e "${BACKUP_FILE}"; then restore_config; fi
  exit 1
fi
if [[ "${WRITE_RESULT}" == UNCHANGED ]]; then
  log_info "Config already matches; no backup or write was needed"
  exit 0
fi
if [[ "${WRITE_RESULT}" != CHANGED ]]; then
  log_error "Unexpected config helper response: ${WRITE_RESULT}"
  if pct exec "${FRIGATE_CT_ID}" -- test -e "${BACKUP_FILE}"; then restore_config; fi
  exit 1
fi
if ! pct exec "${FRIGATE_CT_ID}" -- bash -c \
  'cd -- "$1" && docker compose config >/dev/null' bash "${FRIGATE_APP_DIR}"; then
  log_error "Post-write Docker Compose validation failed"
  restore_config
  exit 1
fi

log_info "Event-only recording config updated and Docker Compose validation passed"
log_info "Backup retained at: ${BACKUP_FILE}"
log_info "Restart Frigate with scripts/step10e-frigate-restart.sh"
log_info "Then validate with scripts/step10p-frigate-event-recording-validation.sh"
