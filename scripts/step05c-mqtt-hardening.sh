#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

log_info "======================================"
log_info "STEP 05C - MQTT AUTHENTICATION HARDENING"
log_info "======================================"

MQTT_CT_ID="${MQTT_CT_ID:-210}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USERNAME="${MQTT_USERNAME:-}"
MQTT_PASSWORD="${MQTT_PASSWORD:-}"
FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
FRIGATE_CONFIG_FILE="${FRIGATE_CONFIG_FILE:-/opt/frigate/config/config.yml}"
FRIGATE_APP_DIR="${FRIGATE_APP_DIR:-/opt/frigate}"

if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi
if [[ -z "${MQTT_USERNAME}" || -z "${MQTT_PASSWORD}" ]]; then
  log_error "Set MQTT_USERNAME and MQTT_PASSWORD in config/local.conf before running"
  exit 1
fi
if [[ "${MQTT_USERNAME}" == "admin" || "${#MQTT_PASSWORD}" -lt 12 ]]; then
  log_error "Use a non-default MQTT username and a password of at least 12 characters"
  exit 1
fi
if [[ "${MQTT_USERNAME}" == *:* || "${MQTT_USERNAME}" == *$'\n'* || "${MQTT_PASSWORD}" == *$'\n'* ]]; then
  log_error "MQTT username/password contains an unsupported newline or username ':' character"
  exit 1
fi

for ct_id in "${MQTT_CT_ID}" "${FRIGATE_CT_ID}"; do
  pct config "${ct_id}" >/dev/null 2>&1 || { log_error "CT ${ct_id} does not exist"; exit 1; }
  pct status "${ct_id}" | grep -q 'status: running' || { log_error "CT ${ct_id} is not running"; exit 1; }
done

for cmd in mosquitto_passwd mosquitto; do
  if ! pct exec "${MQTT_CT_ID}" -- bash -c "command -v '${cmd}' >/dev/null 2>&1"; then
    log_error "Required command is missing inside CT ${MQTT_CT_ID}: ${cmd}"
    exit 1
  fi
done

if ! pct exec "${MQTT_CT_ID}" -- test -f /etc/mosquitto/conf.d/homelab.conf; then
  log_error "Mosquitto configuration does not exist: /etc/mosquitto/conf.d/homelab.conf"
  exit 1
fi
if ! pct exec "${FRIGATE_CT_ID}" -- test -f "${FRIGATE_CONFIG_FILE}"; then
  log_error "Frigate configuration does not exist: ${FRIGATE_CONFIG_FILE}"
  exit 1
fi

MQTT_IP="$({ pct exec "${MQTT_CT_ID}" -- ip -4 -o addr show dev eth0 2>/dev/null || true; } \
  | awk '{ split($4, addr, "/"); print addr[1]; exit }')"
if [[ -z "${MQTT_IP}" ]]; then
  log_error "Could not detect MQTT broker IPv4 address on eth0"
  exit 1
fi

log_info "Backing up Mosquitto configuration"
pct exec "${MQTT_CT_ID}" -- cp /etc/mosquitto/conf.d/homelab.conf \
  "/etc/mosquitto/conf.d/homelab.conf.bak-$(date +%Y%m%d%H%M%S)"
pct exec "${MQTT_CT_ID}" -- cp /etc/mosquitto/passwd \
  "/etc/mosquitto/passwd.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

log_info "Creating Mosquitto password database"
printf '%s\n%s\n' "${MQTT_PASSWORD}" "${MQTT_PASSWORD}" | \
  pct exec "${MQTT_CT_ID}" -- mosquitto_passwd -c /etc/mosquitto/passwd "${MQTT_USERNAME}"

pct exec "${MQTT_CT_ID}" -- chmod 640 /etc/mosquitto/passwd
pct exec "${MQTT_CT_ID}" -- chown mosquitto:mosquitto /etc/mosquitto/passwd
pct exec "${MQTT_CT_ID}" -- bash -c 'cat > /etc/mosquitto/conf.d/homelab.conf.tmp' <<EOF
listener ${MQTT_PORT} 0.0.0.0
allow_anonymous false
password_file /etc/mosquitto/passwd
log_dest syslog
log_dest stdout
EOF
pct exec "${MQTT_CT_ID}" -- mv /etc/mosquitto/conf.d/homelab.conf.tmp /etc/mosquitto/conf.d/homelab.conf

log_info "Updating Frigate MQTT credentials"
pct exec "${FRIGATE_CT_ID}" -- cp "${FRIGATE_CONFIG_FILE}" \
  "${FRIGATE_CONFIG_FILE}.bak-$(date +%Y%m%d%H%M%S)"
printf '%s' "${MQTT_PASSWORD}" | pct exec "${FRIGATE_CT_ID}" -- bash -c 'umask 077; cat > /run/frigate-mqtt-password'
cleanup_frigate_secret() {
  pct exec "${FRIGATE_CT_ID}" -- rm -f /run/frigate-mqtt-password >/dev/null 2>&1 || true
}
trap cleanup_frigate_secret EXIT
pct exec "${FRIGATE_CT_ID}" -- python3 - "${FRIGATE_CONFIG_FILE}" "${MQTT_USERNAME}" "${MQTT_IP}" "${MQTT_PORT}" <<'PY'
import pathlib
import sys
import json

path = pathlib.Path(sys.argv[1])
username, host, port = sys.argv[2:5]
password_path = pathlib.Path("/run/frigate-mqtt-password")
password = password_path.read_text()
lines = path.read_text().splitlines()
out = []
i = 0
while i < len(lines):
    if lines[i] == "mqtt:":
        i += 1
        while i < len(lines) and (not lines[i] or lines[i].startswith((" ", "\t"))):
            i += 1
        continue
    out.append(lines[i])
    i += 1

block = [
    "mqtt:",
    "  enabled: true",
    "  host: " + host,
    "  port: " + port,
    "  user: " + json.dumps(username),
    "  password: " + json.dumps(password),
    "",
]
path.write_text("\n".join(block + out).rstrip() + "\n")
password_path.unlink(missing_ok=True)
PY

if ! pct exec "${FRIGATE_CT_ID}" -- grep -qxF "  host: ${MQTT_IP}" "${FRIGATE_CONFIG_FILE}" \
  || ! pct exec "${FRIGATE_CT_ID}" -- grep -qxF "  port: ${MQTT_PORT}" "${FRIGATE_CONFIG_FILE}" \
  || ! pct exec "${FRIGATE_CT_ID}" -- grep -q '^  user:' "${FRIGATE_CONFIG_FILE}" \
  || ! pct exec "${FRIGATE_CT_ID}" -- grep -q '^  password:' "${FRIGATE_CONFIG_FILE}"; then
  log_error "Frigate MQTT authentication settings were not written correctly"
  exit 1
fi

pct exec "${MQTT_CT_ID}" -- mosquitto -c /etc/mosquitto/mosquitto.conf -t

pct exec "${FRIGATE_CT_ID}" -- bash -c "cd '${FRIGATE_APP_DIR}' && docker compose config >/dev/null"
pct exec "${MQTT_CT_ID}" -- systemctl restart mosquitto
pct exec "${FRIGATE_CT_ID}" -- bash -c "cd '${FRIGATE_APP_DIR}' && docker compose restart frigate"

log_info "MQTT hardening completed"
log_warn "Update the Home Assistant MQTT integration with the same username/password, then run step05d and step10f"
