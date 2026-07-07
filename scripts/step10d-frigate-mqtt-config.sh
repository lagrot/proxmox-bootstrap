#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

log_info "======================================"
log_info "STEP 10D - FRIGATE MQTT CONFIG"
log_info "======================================"

FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
MQTT_CT_ID="${MQTT_CT_ID:-210}"
MQTT_PORT="${MQTT_PORT:-1883}"
FRIGATE_APP_DIR="${FRIGATE_APP_DIR:-/opt/frigate}"
FRIGATE_CONFIG_FILE="${FRIGATE_CONFIG_FILE:-/opt/frigate/config/config.yml}"

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

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required host commands..."
for cmd in pct awk grep date; do
  check_host_command "${cmd}"
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Missing required host commands"
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

if [[ -n "${MQTT_IP}" ]]; then
  log_info "Detected MQTT broker: ${MQTT_IP}:${MQTT_PORT}"
else
  log_error "Could not detect MQTT broker IPv4 address on eth0"
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

log_info "Writing Frigate MQTT settings..."
pct exec "${FRIGATE_CT_ID}" -- python3 - "${FRIGATE_CONFIG_FILE}" "${MQTT_IP}" "${MQTT_PORT}" <<'PY'
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
mqtt_host = sys.argv[2]
mqtt_port = sys.argv[3]

lines = config_path.read_text().splitlines()
out = []
idx = 0

while idx < len(lines):
    line = lines[idx]
    if line == "mqtt:":
        idx += 1
        while idx < len(lines):
            current = lines[idx]
            if current and not current.startswith((" ", "\t")):
                break
            idx += 1
        continue
    out.append(line)
    idx += 1

mqtt_block = [
    "mqtt:",
    "  enabled: true",
    f"  host: {mqtt_host}",
    f"  port: {mqtt_port}",
    "",
]

config_path.write_text("\n".join(mqtt_block + out).rstrip() + "\n")
PY

log_info "Checking rendered Frigate config contains MQTT settings..."
if pct exec "${FRIGATE_CT_ID}" -- grep -qxF '  enabled: true' "${FRIGATE_CONFIG_FILE}" \
  && pct exec "${FRIGATE_CT_ID}" -- grep -qxF "  host: ${MQTT_IP}" "${FRIGATE_CONFIG_FILE}" \
  && pct exec "${FRIGATE_CT_ID}" -- grep -qxF "  port: ${MQTT_PORT}" "${FRIGATE_CONFIG_FILE}"; then
  log_info "Frigate MQTT settings are present"
else
  log_error "Frigate MQTT settings were not written correctly"
  exit 1
fi

log_info "Validating Docker Compose file after config update..."
pct exec "${FRIGATE_CT_ID}" -- bash -c "cd '${FRIGATE_APP_DIR}' && docker compose config >/dev/null"

log_info "Frigate MQTT config updated successfully"
log_info "Restart Frigate with scripts/step10e-frigate-restart.sh"
