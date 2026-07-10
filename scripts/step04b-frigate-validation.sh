#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

log_info "======================================"
log_info "STEP 04B - FRIGATE VALIDATION"
log_info "======================================"

CT_ID="${DOCKER_CT_ID:-200}"
FRIGATE_APP_DIR="${FRIGATE_APP_DIR:-/opt/frigate}"
FRIGATE_CONFIG_DIR="${FRIGATE_CONFIG_DIR:-${FRIGATE_APP_DIR}/config}"
FRIGATE_MEDIA_DIR="${FRIGATE_MEDIA_DIR:-/mnt/frigate}"
FRIGATE_WEB_PORT="${FRIGATE_WEB_PORT:-8971}"

VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0

record_error() {
  log_error "$1"
  ((VALIDATION_ERRORS+=1))
}

record_warn() {
  log_warn "$1"
  ((VALIDATION_WARNINGS+=1))
}

check_host_command() {
  local cmd="$1"

  if command -v "${cmd}" >/dev/null 2>&1; then
    log_info "Host command found: ${cmd}"
  else
    record_error "Required host command not found: ${cmd}"
  fi
}

check_ct_command() {
  local cmd="$1"

  if pct exec "${CT_ID}" -- bash -c "command -v '${cmd}' >/dev/null 2>&1"; then
    log_info "CT command found: ${cmd}"
  else
    record_warn "Command not found inside CT ${CT_ID}: ${cmd}"
  fi
}

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required host commands..."
for cmd in pct grep awk; do
  check_host_command "${cmd}"
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Missing required host commands"
  exit 1
fi

log_info "Checking whether CT ${CT_ID} exists..."
if pct config "${CT_ID}" >/dev/null 2>&1; then
  log_info "CT ${CT_ID} exists"
else
  record_error "CT ${CT_ID} does not exist"
fi

log_info "Checking whether CT ${CT_ID} is running..."
if pct status "${CT_ID}" | grep -q "status: running"; then
  log_info "CT ${CT_ID} is running"
else
  record_error "CT ${CT_ID} is not running"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Cannot continue because CT ${CT_ID} is not ready"
  exit 1
fi

log_info "Checking useful commands inside CT ${CT_ID}..."
check_ct_command docker
check_ct_command curl
check_ct_command find

log_info "Checking Docker service inside CT ${CT_ID}..."
if pct exec "${CT_ID}" -- systemctl is-active --quiet docker; then
  log_info "Docker service is active"
else
  record_error "Docker service is not active inside CT ${CT_ID}"
fi

log_info "Checking Docker Compose inside CT ${CT_ID}..."
if pct exec "${CT_ID}" -- docker compose version >/dev/null 2>&1; then
  log_info "Docker Compose is available"
else
  record_error "Docker Compose is not available inside CT ${CT_ID}"
fi

log_info "Checking Frigate application files..."
if pct exec "${CT_ID}" -- test -f "${FRIGATE_APP_DIR}/docker-compose.yml"; then
  log_info "docker-compose.yml exists"
else
  record_error "${FRIGATE_APP_DIR}/docker-compose.yml does not exist"
fi

if pct exec "${CT_ID}" -- test -f "${FRIGATE_CONFIG_DIR}/config.yml"; then
  log_info "Frigate config.yml exists"
else
  record_error "${FRIGATE_CONFIG_DIR}/config.yml does not exist"
fi

log_info "Checking Frigate media directory layout..."
if pct exec "${CT_ID}" -- test -d "${FRIGATE_MEDIA_DIR}"; then
  log_info "${FRIGATE_MEDIA_DIR} exists inside CT"
else
  record_error "${FRIGATE_MEDIA_DIR} does not exist inside CT"
fi

for dir in clips clips/thumbs recordings snapshots exports; do
  if pct exec "${CT_ID}" -- test -d "${FRIGATE_MEDIA_DIR}/${dir}"; then
    log_info "Media directory exists: ${FRIGATE_MEDIA_DIR}/${dir}"
  else
    record_error "Missing media directory: ${FRIGATE_MEDIA_DIR}/${dir}"
  fi
done

log_info "Checking write access to Frigate media directory..."
if pct exec "${CT_ID}" -- touch "${FRIGATE_MEDIA_DIR}/.validation-write-test"; then
  pct exec "${CT_ID}" -- rm -f "${FRIGATE_MEDIA_DIR}/.validation-write-test"
  log_info "CT ${CT_ID} can write to ${FRIGATE_MEDIA_DIR}"
else
  record_error "CT ${CT_ID} cannot write to ${FRIGATE_MEDIA_DIR}"
fi

log_info "Checking Intel iGPU visibility..."
if pct exec "${CT_ID}" -- test -d /dev/dri; then
  log_info "/dev/dri is visible inside CT"
else
  record_error "/dev/dri is not visible inside CT"
fi

if pct exec "${CT_ID}" -- test -e /dev/dri/renderD128; then
  log_info "/dev/dri/renderD128 is visible inside CT"
else
  record_error "/dev/dri/renderD128 is not visible inside CT"
fi

log_info "Checking USB bus visibility for Coral..."
if pct exec "${CT_ID}" -- test -d /dev/bus/usb; then
  log_info "/dev/bus/usb is visible inside CT"
else
  record_error "/dev/bus/usb is not visible inside CT"
fi

log_info "Checking Coral USB device access..."
CORAL_USB_IDS="$(pct exec "${CT_ID}" -- lsusb 2>/dev/null | grep -E '1a6e:089a|18d1:9302' || true)"
if [[ -n "${CORAL_USB_IDS}" ]]; then
  log_info "Coral USB device is enumerated inside CT"
else
  record_error "Coral USB device is not enumerated inside CT"
fi

log_info "Checking Frigate container state..."
if pct exec "${CT_ID}" -- docker ps --format '{{.Names}}' | grep -qx 'frigate'; then
  log_info "Frigate container is running"
else
  record_error "Frigate container is not running"
fi

log_info "Checking Frigate container health..."
FRIGATE_HEALTH="$(
  pct exec "${CT_ID}" -- docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' frigate 2>/dev/null || true
)"

case "${FRIGATE_HEALTH}" in
  healthy)
    log_info "Frigate container health is healthy"
    ;;
  starting)
    record_warn "Frigate container health is still starting"
    ;;
  unhealthy)
    record_error "Frigate container health is unhealthy"
    ;;
  no-healthcheck)
    record_warn "Frigate container has no Docker healthcheck"
    ;;
  *)
    record_warn "Unknown Frigate health status: ${FRIGATE_HEALTH}"
    ;;
esac

log_info "Checking Frigate HTTPS endpoint..."
if pct exec "${CT_ID}" -- bash -c "command -v curl >/dev/null 2>&1"; then
  HTTP_CODE="$(
    pct exec "${CT_ID}" -- curl -k -s -o /dev/null -w '%{http_code}' "https://127.0.0.1:${FRIGATE_WEB_PORT}" || true
  )"

  case "${HTTP_CODE}" in
    200|301|302|307|308|400|401|403)
      log_info "Frigate HTTPS endpoint responds on port ${FRIGATE_WEB_PORT} with HTTP ${HTTP_CODE}"
      ;;
    000|"")
      record_warn "Frigate HTTPS endpoint did not respond on port ${FRIGATE_WEB_PORT}"
      ;;
    *)
      record_warn "Frigate HTTPS endpoint returned unexpected HTTP status: ${HTTP_CODE}"
      ;;
  esac
else
  record_warn "curl is missing inside CT ${CT_ID}; skipping HTTPS endpoint validation"
fi

log_info "Checking Frigate logs since current container start..."

FRIGATE_STARTED_AT="$(
  pct exec "${CT_ID}" -- docker inspect --format '{{.State.StartedAt}}' frigate 2>/dev/null || true
)"

if [[ -z "${FRIGATE_STARTED_AT}" ]]; then
  record_warn "Could not determine Frigate container start time; falling back to last 200 log lines"
  RECENT_LOGS="$(pct exec "${CT_ID}" -- docker logs --tail 200 frigate 2>&1 || true)"
else
  log_info "Frigate container started at: ${FRIGATE_STARTED_AT}"
  RECENT_LOGS="$(pct exec "${CT_ID}" -- docker logs --since "${FRIGATE_STARTED_AT}" frigate 2>&1 || true)"
fi

if grep -qiE '((ffmpeg|edgetpu|coral|/dev/dri|/dev/bus/usb).*(permission denied))|((permission denied).*(ffmpeg|edgetpu|coral|/dev/dri|/dev/bus/usb))' <<< "${RECENT_LOGS}"; then
  record_error "Frigate logs since current start contain: permission denied"
else
  log_info "No permission denied errors found since current container start"
fi

if grep -qi 'Traceback' <<< "${RECENT_LOGS}"; then
  record_warn "Frigate logs contain a Python traceback; container health and HTTPS status are the source of truth"
else
  log_info "No Python traceback found in checked Frigate logs"
fi
if grep -qi 'Attempting to load TPU as usb' <<< "${RECENT_LOGS}"; then
  log_info "Frigate is attempting to use USB Coral TPU"
else
  record_warn "Current container logs do not show USB Coral TPU initialization"
fi

if grep -qi 'TPU found' <<< "${RECENT_LOGS}"; then
  log_info "Frigate detected the USB Coral TPU"
elif grep -qiE 'No EdgeTPU was detected|Failed to load delegate' <<< "${RECENT_LOGS}"; then
  record_error "Frigate could not initialize the USB Coral TPU"
else
  record_warn "Current container logs do not confirm USB Coral TPU initialization"
fi
CT_IP="$(
  pct exec "${CT_ID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true
)"

log_info "======================================"
log_info "FRIGATE VALIDATION SUMMARY"
log_info "======================================"
log_info "Validation warnings: ${VALIDATION_WARNINGS}"
log_info "Validation errors: ${VALIDATION_ERRORS}"

if [[ -n "${CT_IP}" ]]; then
  log_info "Frigate URL: https://${CT_IP}:${FRIGATE_WEB_PORT}"
else
  record_warn "Could not determine CT IP address"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Frigate validation failed"
  exit 1
fi

if [[ "${VALIDATION_WARNINGS}" -gt 0 ]]; then
  log_warn "Frigate validation completed with warnings"
  exit 0
fi

log_info "Frigate validation completed successfully"
