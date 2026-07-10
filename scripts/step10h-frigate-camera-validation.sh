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

log_info "=========================================="
log_info "STEP 10H - FRIGATE CAMERA VALIDATION"
log_info "=========================================="

FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
FRIGATE_APP_DIR="${FRIGATE_APP_DIR:-/opt/frigate}"
FRIGATE_CONFIG_FILE="${FRIGATE_CONFIG_FILE:-/opt/frigate/config/config.yml}"
FRIGATE_WEB_PORT="${FRIGATE_WEB_PORT:-8971}"

CAMERA_NAME="${TAPO_CAMERA_NAME:-tapo_c200}"
CAMERA_IP="${TAPO_CAMERA_IP:-}"
CAMERA_USERNAME="${TAPO_CAMERA_USERNAME:-}"
CAMERA_PASSWORD="${TAPO_CAMERA_PASSWORD:-}"
CAMERA_RTSP_PORT="${TAPO_CAMERA_RTSP_PORT:-554}"
CAMERA_RECORD_STREAM_PATH="${TAPO_CAMERA_RECORD_STREAM_PATH:-/stream1}"
CAMERA_DETECT_STREAM_PATH="${TAPO_CAMERA_DETECT_STREAM_PATH:-/stream2}"
FRIGATE_USERNAME="${FRIGATE_USERNAME:-}"
FRIGATE_PASSWORD="${FRIGATE_PASSWORD:-}"

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

detect_ct_eth0_ipv4() {
  local ct_id="$1"

  pct exec "${ct_id}" -- ip -4 -o addr show dev eth0 2>/dev/null \
    | awk '{ split($4, addr, "/"); print addr[1]; exit }' || true
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
for cmd in pct awk grep curl; do
  check_host_command "${cmd}"
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Missing required host commands"
  exit 1
fi

log_info "Checking CT ${FRIGATE_CT_ID}..."
if pct status "${FRIGATE_CT_ID}" 2>/dev/null | grep -q "status: running"; then
  log_info "CT ${FRIGATE_CT_ID} is running"
else
  log_error "CT ${FRIGATE_CT_ID} is not running"
  exit 1
fi

CT_IP="$(detect_ct_eth0_ipv4 "${FRIGATE_CT_ID}")"
if [[ -n "${CT_IP}" ]]; then
  log_info "Detected Frigate CT IP: ${CT_IP}"
else
  record_error "Could not detect Frigate CT IPv4 address on eth0"
fi

log_info "Checking Frigate config file..."
if pct exec "${FRIGATE_CT_ID}" -- test -f "${FRIGATE_CONFIG_FILE}"; then
  log_info "Frigate config file exists"
else
  log_error "Frigate config file does not exist: ${FRIGATE_CONFIG_FILE}"
  exit 1
fi

if pct exec "${FRIGATE_CT_ID}" -- grep -qxF "  ${CAMERA_NAME}:" "${FRIGATE_CONFIG_FILE}"; then
  log_info "Camera entry exists: ${CAMERA_NAME}"
else
  record_error "Camera entry not found in Frigate config: ${CAMERA_NAME}"
fi

if [[ -n "${CAMERA_IP}" ]]; then
  if pct exec "${FRIGATE_CT_ID}" -- grep -q "${CAMERA_IP}" "${FRIGATE_CONFIG_FILE}"; then
    log_info "Frigate config references camera IP ${CAMERA_IP}"
  else
    record_error "Frigate config does not reference expected camera IP ${CAMERA_IP}"
  fi
else
  record_warn "TAPO_CAMERA_IP is not set; skipping camera IP check"
fi

log_info "Validating Docker Compose file..."
pct exec "${FRIGATE_CT_ID}" -- bash -c "cd '${FRIGATE_APP_DIR}' && docker compose config >/dev/null"

log_info "Checking Frigate container state..."
if pct exec "${FRIGATE_CT_ID}" -- docker ps --format '{{.Names}}' | grep -qx 'frigate'; then
  log_info "Frigate container is running"
else
  record_error "Frigate container is not running"
fi

if FFMPEG_BIN="$(pct exec "${FRIGATE_CT_ID}" -- bash -c 'command -v ffmpeg || true' 2>/dev/null)"; [[ -n "${FFMPEG_BIN}" ]]; then
  log_info "FFmpeg is available in CT ${FRIGATE_CT_ID}: ${FFMPEG_BIN}"
else
  record_error "FFmpeg is not available in CT ${FRIGATE_CT_ID}; rerun the Frigate deployment step"
fi

test_rtsp_stream() {
  local stream_label="$1"
  local stream_path="$2"
  local output_file="/tmp/${CAMERA_NAME}-${stream_label}.mp4"
  local rtsp_url

  if [[ -z "${CAMERA_IP}" || -z "${CAMERA_USERNAME}" || -z "${CAMERA_PASSWORD}" ]]; then
    record_warn "Skipping direct RTSP ${stream_label} test; set TAPO_CAMERA_IP, TAPO_CAMERA_USERNAME, and TAPO_CAMERA_PASSWORD"
    return
  fi

  rtsp_url="rtsp://${CAMERA_USERNAME}:${CAMERA_PASSWORD}@${CAMERA_IP}:${CAMERA_RTSP_PORT}${stream_path}"

  log_info "Testing direct RTSP ${stream_label} stream inside CT ${FRIGATE_CT_ID}..."
  if [[ -z "${FFMPEG_BIN:-}" ]]; then
    record_error "Cannot test RTSP ${stream_label}; Frigate FFmpeg path is unknown"
    return
  fi

  if pct exec "${FRIGATE_CT_ID}" -- "${FFMPEG_BIN}" -hide_banner -loglevel error -rtsp_transport tcp -y -i "${rtsp_url}" -t 1 "${output_file}" >/dev/null 2>&1; then
    log_info "Direct RTSP ${stream_label} stream is accessible"
  else
    record_error "Direct RTSP ${stream_label} stream test failed"
  fi

  pct exec "${FRIGATE_CT_ID}" -- rm -f "${output_file}" >/dev/null 2>&1 || true
}

test_rtsp_stream "record" "${CAMERA_RECORD_STREAM_PATH}"
test_rtsp_stream "detect" "${CAMERA_DETECT_STREAM_PATH}"

FRIGATE_HEALTH="$(
  pct exec "${FRIGATE_CT_ID}" -- docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' frigate 2>/dev/null || true
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
  *)
    record_warn "Unexpected Frigate health state: ${FRIGATE_HEALTH}"
    ;;
esac

if [[ -n "${CT_IP}" && -n "${FRIGATE_USERNAME}" && -n "${FRIGATE_PASSWORD}" ]]; then
  API_CODE="$(
    pct exec "${FRIGATE_CT_ID}" -- curl -k -s -o /tmp/frigate-api-config.out -w '%{http_code}' \
      -u "${FRIGATE_USERNAME}:${FRIGATE_PASSWORD}" \
      "https://127.0.0.1:${FRIGATE_WEB_PORT}/api/config" || true
  )"

  case "${API_CODE}" in
    200)
      if pct exec "${FRIGATE_CT_ID}" -- grep -q "\"${CAMERA_NAME}\"" /tmp/frigate-api-config.out; then
        log_info "Frigate API reports camera ${CAMERA_NAME}"
      else
        record_warn "Frigate API responded, but camera ${CAMERA_NAME} was not found in /api/config"
      fi
      ;;
    401|403)
      record_warn "Frigate API authentication failed; check FRIGATE_USERNAME and FRIGATE_PASSWORD"
      ;;
    *)
      record_warn "Frigate API returned HTTP ${API_CODE}; skipping API camera verification"
      ;;
  esac
else
  record_warn "FRIGATE_USERNAME and FRIGATE_PASSWORD not set; skipping Frigate API verification"
fi

log_info "Checking recent Frigate logs for camera-specific failures..."
FRIGATE_STARTED_AT="$(
  pct exec "${FRIGATE_CT_ID}" -- docker inspect --format '{{.State.StartedAt}}' frigate 2>/dev/null || true
)"

if [[ -n "${FRIGATE_STARTED_AT}" ]]; then
  RECENT_LOGS="$(pct exec "${FRIGATE_CT_ID}" -- docker logs --since "${FRIGATE_STARTED_AT}" frigate 2>&1 || true)"
else
  RECENT_LOGS="$(pct exec "${FRIGATE_CT_ID}" -- docker logs --tail 250 frigate 2>&1 || true)"
fi

if grep -qiE "${CAMERA_NAME}.*(error|failed|timed out|timeout|unauthorized|401|no frames|unable|invalid data)" <<< "${RECENT_LOGS}"; then
  record_error "Recent Frigate logs contain camera-specific error messages for ${CAMERA_NAME}"
elif grep -qi "${CAMERA_NAME}" <<< "${RECENT_LOGS}"; then
  log_info "Recent Frigate logs mention camera ${CAMERA_NAME}"
else
  record_warn "Recent Frigate logs do not mention camera ${CAMERA_NAME} yet"
fi

log_info "=========================================="
log_info "FRIGATE CAMERA VALIDATION SUMMARY"
log_info "=========================================="
log_info "Validation warnings: ${VALIDATION_WARNINGS}"
log_info "Validation errors: ${VALIDATION_ERRORS}"

if [[ -n "${CT_IP}" ]]; then
  log_info "Frigate URL: https://${CT_IP}:${FRIGATE_WEB_PORT}"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Frigate camera validation failed"
  exit 1
fi

if [[ "${VALIDATION_WARNINGS}" -gt 0 ]]; then
  log_warn "Frigate camera validation completed with warnings"
  exit 0
fi

log_info "Frigate camera validation completed successfully"
