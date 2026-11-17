#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

for arg in "$@"; do
  if [[ "${arg}" == "--dry-run" ]]; then
    LOG_FILE=/dev/null
    break
  fi
done

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--dry-run]

Configure Frigate to use the runtime IPv4 address of the MQTT CT.
The operation preserves other MQTT settings, including credentials.
EOF
      exit 0
      ;;
    *) log_error "Unknown argument: ${arg}"; exit 1 ;;
  esac
done

log_info "======================================"
log_info "STEP 10D - FRIGATE MQTT CONFIG"
log_info "======================================"

FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
MQTT_CT_ID="${MQTT_CT_ID:-210}"
MQTT_PORT="${MQTT_PORT:-1883}"
FRIGATE_APP_DIR="${FRIGATE_APP_DIR:-/opt/frigate}"
FRIGATE_CONFIG_FILE="${FRIGATE_CONFIG_FILE:-/opt/frigate/config/config.yml}"
MQTT_CONFIG_HELPER="${SCRIPT_DIR}/../lib/frigate-mqtt-config.py"
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

detect_ct_eth0_ipv4() {
  local ct_id="$1"
  pct exec "${ct_id}" -- ip -4 -o addr show dev eth0 2>/dev/null \
    | awk '{ split($4, addr, "/"); print addr[1]; exit }' || true
}

run_compose_config_check() {
  pct exec "${FRIGATE_CT_ID}" -- bash -c \
    'cd "$1" && docker compose config >/dev/null' bash "${FRIGATE_APP_DIR}"
}

restore_config() {
  local backup_file="$1"
  if pct exec "${FRIGATE_CT_ID}" -- cp "${backup_file}" "${FRIGATE_CONFIG_FILE}"; then
    log_error "Restored Frigate config from backup: ${backup_file}"
  else
    log_error "Automatic config restore failed; recovery copy remains at: ${backup_file}"
  fi
}

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required host commands..."
for cmd in pct awk grep date python3; do
  check_host_command "${cmd}"
done
[[ -f "${MQTT_CONFIG_HELPER}" ]] || record_error "Missing helper: ${MQTT_CONFIG_HELPER}"
[[ "${FRIGATE_CT_ID}" =~ ^[0-9]+$ && "${MQTT_CT_ID}" =~ ^[0-9]+$ ]] \
  || record_error "Container IDs must be numeric"
if ! [[ "${MQTT_PORT}" =~ ^[0-9]{1,5}$ ]] || ((10#${MQTT_PORT:-0} < 1 || 10#${MQTT_PORT:-0} > 65535)); then
  record_error "MQTT_PORT must be an integer from 1 through 65535"
fi
if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Cannot continue because preflight checks failed"
  exit 1
fi

for ct_id in "${FRIGATE_CT_ID}" "${MQTT_CT_ID}"; do
  log_info "Checking CT ${ct_id}..."
  if pct config "${ct_id}" >/dev/null 2>&1; then
    log_info "CT ${ct_id} exists"
  else
    record_error "CT ${ct_id} does not exist"
  fi
  if pct status "${ct_id}" 2>/dev/null | grep -q "status: running"; then
    log_info "CT ${ct_id} is running"
  else
    record_error "CT ${ct_id} is not running"
  fi
done
if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Cannot continue because required CTs are not ready"
  exit 1
fi

log_info "Detecting MQTT broker IP from CT ${MQTT_CT_ID} eth0..."
MQTT_IP="$(detect_ct_eth0_ipv4 "${MQTT_CT_ID}")"
if [[ -z "${MQTT_IP}" ]] || ! python3 - "${MQTT_IP}" "${MQTT_PORT}" <<'PY'
import ipaddress
import sys

try:
    ipaddress.IPv4Address(sys.argv[1])
    port = int(sys.argv[2])
    if not 1 <= port <= 65535:
        raise ValueError
except ValueError:
    raise SystemExit(1)
PY
then
  log_error "Could not determine a valid MQTT broker IPv4 address and port"
  exit 1
fi
log_info "Detected MQTT broker: ${MQTT_IP}:${MQTT_PORT}"

log_info "Checking Frigate config file..."
if ! pct exec "${FRIGATE_CT_ID}" -- test -f "${FRIGATE_CONFIG_FILE}"; then
  log_error "Frigate config file does not exist: ${FRIGATE_CONFIG_FILE}"
  exit 1
fi
if ! pct exec "${FRIGATE_CT_ID}" -- docker compose version >/dev/null 2>&1; then
  log_error "Docker Compose is unavailable inside CT ${FRIGATE_CT_ID}"
  exit 1
fi

log_info "Checking whether Frigate MQTT settings need an update..."
if ! CHANGE_NEEDED="$(pct exec "${FRIGATE_CT_ID}" -- python3 - "${FRIGATE_CONFIG_FILE}" "${MQTT_IP}" "${MQTT_PORT}" --check <"${MQTT_CONFIG_HELPER}")"; then
  log_error "Could not inspect Frigate MQTT configuration"
  exit 1
fi
case "${CHANGE_NEEDED}" in
  unchanged)
    log_info "Frigate MQTT settings already match; no backup or write is needed"
    if ! run_compose_config_check; then
      log_error "Docker Compose configuration validation failed"
      exit 1
    fi
    log_info "Frigate MQTT configuration is valid and unchanged"
    exit 0
    ;;
  changed) ;;
  *) log_error "Unexpected config inspection result"; exit 1 ;;
esac

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] Would update only MQTT enabled/host/port in ${FRIGATE_CONFIG_FILE}"
  log_info "[DRY-RUN] Existing MQTT credentials and other settings will be preserved"
  log_info "No backup or configuration write was made"
  exit 0
fi

BACKUP_STAMP="$(date +%Y%m%d%H%M%S)"
log_info "Creating a unique, protected Frigate config backup..."
if ! BACKUP_FILE="$(pct exec "${FRIGATE_CT_ID}" -- mktemp "${FRIGATE_CONFIG_FILE}.bak-${BACKUP_STAMP}.XXXXXX")"; then
  log_error "Could not allocate a unique Frigate config backup path"
  exit 1
fi
if ! pct exec "${FRIGATE_CT_ID}" -- cp "${FRIGATE_CONFIG_FILE}" "${BACKUP_FILE}" \
  || ! pct exec "${FRIGATE_CT_ID}" -- chmod 0600 "${BACKUP_FILE}"; then
  pct exec "${FRIGATE_CT_ID}" -- rm -f "${BACKUP_FILE}" >/dev/null 2>&1 || true
  log_error "Could not create a protected Frigate config backup"
  exit 1
fi
log_info "Frigate config backup created: ${BACKUP_FILE}"

log_info "Updating Frigate MQTT settings atomically..."
if ! pct exec "${FRIGATE_CT_ID}" -- python3 - "${FRIGATE_CONFIG_FILE}" "${MQTT_IP}" "${MQTT_PORT}" <"${MQTT_CONFIG_HELPER}"; then
  restore_config "${BACKUP_FILE}"
  exit 1
fi

log_info "Checking rendered Frigate MQTT settings..."
if ! pct exec "${FRIGATE_CT_ID}" -- grep -qxF '  enabled: true' "${FRIGATE_CONFIG_FILE}" \
  || ! pct exec "${FRIGATE_CT_ID}" -- grep -qxF "  host: ${MQTT_IP}" "${FRIGATE_CONFIG_FILE}" \
  || ! pct exec "${FRIGATE_CT_ID}" -- grep -qxF "  port: ${MQTT_PORT}" "${FRIGATE_CONFIG_FILE}"; then
  restore_config "${BACKUP_FILE}"
  log_error "Frigate MQTT settings were not written correctly"
  exit 1
fi

log_info "Validating Docker Compose file after config update..."
if ! run_compose_config_check; then
  restore_config "${BACKUP_FILE}"
  log_error "Docker Compose validation failed; config was rolled back"
  exit 1
fi

log_info "Frigate MQTT config updated successfully"
log_info "Other MQTT settings and credentials were preserved"
log_info "Restart Frigate with scripts/step10e-frigate-restart.sh"
