#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$BASH_SOURCE")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/config/defaults.conf"
if [[ -f "$PROJECT_ROOT/config/local.conf" ]]; then
  source "$PROJECT_ROOT/config/local.conf"
fi

set +u
HA_TOKEN="$HA_TOKEN"
set -u

log_info "=============================================="
log_info "STEP 10N - FRIGATE HOME ASSISTANT SMOKE TEST"
log_info "=============================================="

FRIGATE_CT_ID="$DOCKER_CT_ID"
MQTT_CT_ID="$MQTT_CT_ID"
HA_VM_ID="$HA_VM_ID"
MQTT_PORT="$MQTT_PORT"
MQTT_USERNAME="${MQTT_USERNAME:-}"
MQTT_PASSWORD="${MQTT_PASSWORD:-}"
FRIGATE_INTERNAL_PORT="$FRIGATE_INTERNAL_PORT"
HA_HTTP_PORT="$HA_HTTP_PORT"
HA_CAMERA_ENTITY="camera.tplink_c200_1"
RECORDING_LOOKBACK_MINUTES="30"
MQTT_EVENT_WAIT_SECONDS="20"

WORK_DIR="$(mktemp -d /tmp/frigate-ha-smoketest.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

check_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing host command $1"
    return 1
  }
}

detect_ct_ip() {
  pct exec "$1" -- ip -4 -o addr show dev eth0 2>/dev/null |
    awk '{ split($4, addr, "/"); print addr[1]; exit }' || true
}

detect_ha_ip() {
  qm agent "$HA_VM_ID" network-get-interfaces 2>/dev/null |
    awk '
      /"ip-address" :/ { ip=$3; gsub(/[",]/, "", ip) }
      /"ip-address-type" : "ipv4"/ {
        if (ip !~ /^127\./ && ip !~ /^169\.254\./ && ip !~ /^172\.30\./) { print ip; exit }
      }
    ' || true
}

track_frigate() {
  echo "INFO: checking Frigate service and integration endpoint"
  pct status "$FRIGATE_CT_ID" 2>/dev/null | grep -q 'status: running' ||
    { echo "ERROR: Frigate CT is not running"; return 1; }
  pct exec "$FRIGATE_CT_ID" -- docker ps --format '{{.Names}}' | grep -qx frigate ||
    { echo "ERROR: Frigate container is not running"; return 1; }
  health="$(pct exec "$FRIGATE_CT_ID" -- docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' frigate 2>/dev/null || true)"
  [[ "$health" == healthy ]] || { echo "ERROR: Frigate health is $health"; return 1; }
  frigate_ip="$(detect_ct_ip "$FRIGATE_CT_ID")"
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://$frigate_ip:$FRIGATE_INTERNAL_PORT" || true)"
  [[ "$http_code" =~ ^(200|301|302|307|308|400|401|403)$ ]] ||
    { echo "ERROR: Frigate endpoint returned HTTP $http_code"; return 1; }
  pct exec "$FRIGATE_CT_ID" -- grep -q tplink_c200_1 /opt/frigate/config/config.yml ||
    { echo "ERROR: Tapo C200 is absent from Frigate config"; return 1; }
  echo "INFO: Frigate service and camera configuration are healthy"
}

track_homeassistant() {
  echo "INFO: checking Home Assistant Frigate entities"
  [[ -n "$HA_TOKEN" ]] || { echo "ERROR: HA_TOKEN is not set"; return 1; }
  ha_ip="$(detect_ha_ip)"
  [[ -n "$ha_ip" ]] || { echo "ERROR: Home Assistant IP not detected"; return 1; }
  api_code="$(curl -sS -o "$WORK_DIR/ha-states.json" -w '%{http_code}' \
    -H "Authorization: Bearer $HA_TOKEN" --max-time 15 \
    "http://$ha_ip:$HA_HTTP_PORT/api/states" || true)"
  [[ "$api_code" == 200 ]] || { echo "ERROR: Home Assistant API returned HTTP $api_code"; return 1; }
  python3 -c '
import json, sys
camera = sys.argv[1]
states = json.load(sys.stdin)
required = {camera, "switch.tplink_c200_1_detect", "switch.tplink_c200_1_recordings",
            "switch.tplink_c200_1_snapshots", "binary_sensor.tplink_c200_1_motion",
            "sensor.tplink_c200_1_review_status"}
available = {item.get("entity_id") for item in states}
missing = sorted(required - available)
if missing:
    print("missing=" + ",".join(missing))
    raise SystemExit(1)
state = next(item.get("state") for item in states if item.get("entity_id") == camera)
print("camera_state=" + str(state))
if state in {"unknown", "unavailable"}:
    raise SystemExit(2)
' "$HA_CAMERA_ENTITY" < "$WORK_DIR/ha-states.json" ||
    { echo "ERROR: required Home Assistant entities are missing or unavailable"; return 1; }
  echo "INFO: Home Assistant camera and Frigate control entities are available"
}

track_recording() {
  echo "INFO: checking recent recording output"
  recordings="$(pct exec "$FRIGATE_CT_ID" -- find /mnt/frigate/recordings -type f -name '*.mp4' \
    -mmin "-$RECORDING_LOOKBACK_MINUTES" 2>/dev/null | head -1 || true)"
  if [[ -n "$recordings" ]]; then
    echo "INFO: recent recording segment found"
  else
    echo "WARN: no recording segment found in the last $RECORDING_LOOKBACK_MINUTES minutes"
    echo "WARN: confirm recording is enabled and retry"
  fi
}

track_mqtt() {
  echo "INFO: checking MQTT availability and live Frigate events"
  pct status "$MQTT_CT_ID" 2>/dev/null | grep -q 'status: running' ||
    { echo "ERROR: MQTT CT is not running"; return 1; }
  [[ -n "$MQTT_USERNAME" && -n "$MQTT_PASSWORD" ]] ||
    { echo "ERROR: MQTT_USERNAME and MQTT_PASSWORD are not configured"; return 1; }

  client_home="/tmp/frigate-ha-smoketest-mqtt-${BASHPID}"
  cleanup_mqtt_client() {
    pct exec "$MQTT_CT_ID" -- rm -rf "$client_home" >/dev/null 2>&1 || true
  }
  trap cleanup_mqtt_client RETURN
  printf '%s\n' "-h 127.0.0.1" "-p $MQTT_PORT" "-u $MQTT_USERNAME" "-P $MQTT_PASSWORD" |
    pct exec "$MQTT_CT_ID" -- bash -c "umask 077; mkdir -p '$client_home/.config'; cat > '$client_home/.config/mosquitto_sub'"

  availability="$(pct exec "$MQTT_CT_ID" -- bash -c \
    "HOME='$client_home' XDG_CONFIG_HOME='$client_home/.config' timeout 15 mosquitto_sub -t frigate/available -C 1 -W 10 2>/dev/null" || true)"
  [[ "$availability" == online ]] || { echo "ERROR: Frigate MQTT availability is $availability"; return 1; }
  echo "INFO: Frigate MQTT availability is online"
  echo "INFO: move in front of the camera during the next $MQTT_EVENT_WAIT_SECONDS seconds"
  event_payload="$(pct exec "$MQTT_CT_ID" -- bash -c \
    "HOME='$client_home' XDG_CONFIG_HOME='$client_home/.config' timeout '$MQTT_EVENT_WAIT_SECONDS' mosquitto_sub -t frigate/events -C 1 -W '$MQTT_EVENT_WAIT_SECONDS' 2>/dev/null" || true)"
  if [[ -n "$event_payload" ]]; then
    echo "INFO: live Frigate MQTT event received"
  else
    echo "WARN: no live Frigate MQTT event received during the wait window"
  fi
}

for cmd in pct qm awk grep curl python3; do
  check_command "$cmd" || exit 1
done
[[ "$EUID" -eq 0 ]] || { log_error "This script must be run as root"; exit 1; }

log_info "Running smoke-test tracks in parallel..."
track_frigate >"$WORK_DIR/frigate.log" 2>&1 & frigate_pid=$!
track_homeassistant >"$WORK_DIR/homeassistant.log" 2>&1 & homeassistant_pid=$!
track_recording >"$WORK_DIR/recording.log" 2>&1 & recording_pid=$!
track_mqtt >"$WORK_DIR/mqtt.log" 2>&1 & mqtt_pid=$!

track_failures=0
for track in frigate homeassistant recording mqtt; do
  pid_var="$track"_pid
  declare -n track_pid="$pid_var"
  if ! wait "$track_pid"; then ((track_failures+=1)); fi
  unset -n track_pid
done

for track in frigate homeassistant recording mqtt; do
  log_info "----- $track track -----"
  sed 's/^/  /' "$WORK_DIR/$track.log"
done

log_info "=============================================="
log_info "FRIGATE HOME ASSISTANT SMOKE TEST SUMMARY"
log_info "=============================================="
log_info "Failed tracks: $track_failures"
if [[ "$track_failures" -gt 0 ]]; then
  log_error "Smoke test failed"
  exit 1
fi
if grep -Rqs '^WARN:' "$WORK_DIR"; then
  log_warn "Smoke test passed with activity-dependent warnings"
else
  log_info "Smoke test completed successfully"
fi
