#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

MQTT_CT_ID="${MQTT_CT_ID:-210}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USERNAME="${MQTT_USERNAME:-}"
MQTT_PASSWORD="${MQTT_PASSWORD:-}"

[[ "${EUID}" -eq 0 ]] || { log_error "This script must be run as root"; exit 1; }
[[ -n "${MQTT_USERNAME}" && -n "${MQTT_PASSWORD}" ]] || { log_error "MQTT credentials are missing from config/local.conf"; exit 1; }
[[ "${MQTT_USERNAME}" != *:* ]] || { log_error "MQTT_USERNAME must not contain ':'"; exit 1; }
pct status "${MQTT_CT_ID}" | grep -q 'status: running' || { log_error "CT ${MQTT_CT_ID} is not running"; exit 1; }

TOPIC="homelab/auth-validation"
MESSAGE="mqtt-auth-validation-$(date +%s)"
CLIENT_HOME="/tmp/mqtt-auth-validation-home"
trap 'pct exec "${MQTT_CT_ID}" -- rm -rf "${CLIENT_HOME}" >/dev/null 2>&1 || true' EXIT

printf '%s\n' "-h 127.0.0.1" "-p ${MQTT_PORT}" "-u ${MQTT_USERNAME}" "-P ${MQTT_PASSWORD}" \
  | pct exec "${MQTT_CT_ID}" -- bash -c "umask 077; mkdir -p '${CLIENT_HOME}/.config'; cat > '${CLIENT_HOME}/.config/mosquitto_sub'; cp '${CLIENT_HOME}/.config/mosquitto_sub' '${CLIENT_HOME}/.config/mosquitto_pub'"

log_info "Testing authenticated publish/subscribe"
pct exec "${MQTT_CT_ID}" -- bash -c "
  HOME='${CLIENT_HOME}' XDG_CONFIG_HOME='${CLIENT_HOME}/.config' timeout 10 mosquitto_sub -t '${TOPIC}' -C 1 > /tmp/mqtt-auth-validation.out &
  pid=\$!
  sleep 1
  HOME='${CLIENT_HOME}' XDG_CONFIG_HOME='${CLIENT_HOME}/.config' mosquitto_pub -t '${TOPIC}' -m '${MESSAGE}'
  wait \${pid}
  grep -qx '${MESSAGE}' /tmp/mqtt-auth-validation.out
  rm -f /tmp/mqtt-auth-validation.out
"
log_info "Authenticated MQTT access works"

log_info "Testing that anonymous access is rejected"
if pct exec "${MQTT_CT_ID}" -- mosquitto_pub -h 127.0.0.1 -p "${MQTT_PORT}" -t "${TOPIC}" -m rejected >/dev/null 2>&1; then
  log_error "Anonymous MQTT publish was accepted"
  exit 1
fi
log_info "Anonymous MQTT access is rejected"
log_info "Testing that anonymous subscription is rejected"
if pct exec "${MQTT_CT_ID}" -- timeout 3 mosquitto_sub -h 127.0.0.1 -p "${MQTT_PORT}" -t "${TOPIC}" -C 1 -W 2 >/dev/null 2>&1; then
  log_error "Anonymous MQTT subscription was accepted"
  exit 1
fi
log_info "Anonymous MQTT subscription is rejected or receives no unauthorized data"
log_info "MQTT authentication validation completed successfully"
