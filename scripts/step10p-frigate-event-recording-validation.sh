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

log_info "===================================================="
log_info "STEP 10P - FRIGATE EVENT RECORDING VALIDATION"
log_info "===================================================="

FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
FRIGATE_INTERNAL_PORT="${FRIGATE_INTERNAL_PORT:-5000}"
EVENT_RECORDING_DAYS="${FRIGATE_EVENT_RECORDING_DAYS:-10}"
EVENT_PRE_CAPTURE_SECONDS="${FRIGATE_EVENT_PRE_CAPTURE_SECONDS:-5}"
EVENT_POST_CAPTURE_SECONDS="${FRIGATE_EVENT_POST_CAPTURE_SECONDS:-5}"
CAMERA_NAMES=(
  "${TAPO_C200_NAME:-${TAPO_CAMERA_NAME:-tplink_c200_1}}"
  "${TAPO_C320WS_NAME:-tplink_c320ws_1}"
)

VALIDATION_ERRORS=0

record_error() {
  log_error "$1"
  ((VALIDATION_ERRORS+=1))
}

if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

if ! pct status "${FRIGATE_CT_ID}" 2>/dev/null | grep -q "status: running"; then
  log_error "CT ${FRIGATE_CT_ID} is not running"
  exit 1
fi

FRIGATE_IP="$(pct exec "${FRIGATE_CT_ID}" -- ip -4 -o addr show dev eth0 2>/dev/null \
  | awk '{ split($4, addr, "/"); print addr[1]; exit }' || true)"
if [[ -z "${FRIGATE_IP}" ]]; then
  log_error "Could not detect Frigate CT IPv4 address"
  exit 1
fi

log_info "Checking Frigate container health..."
if ! pct exec "${FRIGATE_CT_ID}" -- docker ps --format '{{.Names}}' | grep -qx frigate; then
  record_error "Frigate container is not running"
fi

HEALTH="$(pct exec "${FRIGATE_CT_ID}" -- docker inspect \
  --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' frigate 2>/dev/null || true)"
if [[ "${HEALTH}" == "healthy" ]]; then
  log_info "Frigate container is healthy"
else
  record_error "Unexpected Frigate container health: ${HEALTH:-unknown}"
fi

log_info "Checking effective Frigate event retention through the API..."
CONFIG_JSON="$(curl -fsS --max-time 15 "http://${FRIGATE_IP}:${FRIGATE_INTERNAL_PORT}/api/config" || true)"
if [[ -z "${CONFIG_JSON}" ]]; then
  record_error "Could not read effective Frigate config"
else
  API_CONFIG_FILE="$(pct exec "${FRIGATE_CT_ID}" -- mktemp /tmp/frigate-event-recording-config.XXXXXX)"
  trap 'pct exec "${FRIGATE_CT_ID}" -- rm -f "${API_CONFIG_FILE}" >/dev/null 2>&1 || true' EXIT
  printf '%s' "${CONFIG_JSON}" | pct exec "${FRIGATE_CT_ID}" -- bash -c \
    "umask 077; cat > '${API_CONFIG_FILE}'"

  if pct exec "${FRIGATE_CT_ID}" -- python3 - \
    "${API_CONFIG_FILE}" \
    "${EVENT_RECORDING_DAYS}" \
    "${EVENT_PRE_CAPTURE_SECONDS}" \
    "${EVENT_POST_CAPTURE_SECONDS}" \
    "${CAMERA_NAMES[@]}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = json.load(config_file)
expected_days = float(sys.argv[2])
expected_pre = int(sys.argv[3])
expected_post = int(sys.argv[4])
camera_names = sys.argv[5:]

def validate_record(record, context):
    errors = []
    if not record.get("enabled"):
        errors.append(f"{context}: recording is disabled")
    if float(record.get("continuous", {}).get("days", -1)) != 0:
        errors.append(f"{context}: continuous retention is not zero")
    if float(record.get("motion", {}).get("days", -1)) != 0:
        errors.append(f"{context}: motion retention is not zero")
    for event_type in ("alerts", "detections"):
        event = record.get(event_type, {})
        retain = event.get("retain", {})
        if float(retain.get("days", -1)) != expected_days:
            errors.append(f"{context}: {event_type} retention is not {expected_days:g} days")
        if retain.get("mode") != "motion":
            errors.append(f"{context}: {event_type} retention mode is not motion")
        if event.get("pre_capture") != expected_pre:
            errors.append(f"{context}: {event_type} pre_capture is not {expected_pre}")
        if event.get("post_capture") != expected_post:
            errors.append(f"{context}: {event_type} post_capture is not {expected_post}")
    return errors

errors = validate_record(config.get("record", {}), "global config")
for camera_name in camera_names:
    camera = config.get("cameras", {}).get(camera_name)
    if camera is None:
        errors.append(f"camera missing: {camera_name}")
        continue
    errors.extend(validate_record(camera.get("record", {}), camera_name))

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
  then
    log_info "Both cameras use event-only video retention"
  else
    record_error "Effective event recording policy does not match"
  fi
fi

log_info "Checking current Frigate logs for configuration errors..."
FRIGATE_STARTED_AT="$(pct exec "${FRIGATE_CT_ID}" -- docker inspect --format '{{.State.StartedAt}}' frigate 2>/dev/null || true)"
if [[ -n "${FRIGATE_STARTED_AT}" ]]; then
  RECENT_LOGS="$(pct exec "${FRIGATE_CT_ID}" -- docker logs --since "${FRIGATE_STARTED_AT}" frigate 2>&1 || true)"
else
  RECENT_LOGS="$(pct exec "${FRIGATE_CT_ID}" -- docker logs --tail 250 frigate 2>&1 || true)"
fi
if grep -qiE '(config|record).*(error|invalid|failed)' <<< "${RECENT_LOGS}"; then
  record_error "Frigate logs contain configuration or recording errors"
else
  log_info "No configuration or recording errors found since current start"
fi

log_info "============================================"
log_info "FRIGATE EVENT RECORDING VALIDATION SUMMARY"
log_info "============================================"
log_info "Validation errors: ${VALIDATION_ERRORS}"

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Frigate event recording validation failed"
  exit 1
fi

log_info "Frigate event-only recording validation completed successfully"
