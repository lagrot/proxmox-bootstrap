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

HA_VM_ID="${HA_VM_ID:-100}"
HA_TOKEN="${HA_TOKEN:-}"
HA_CLIMATE_DASHBOARD_URL_PATH="${HA_CLIMATE_DASHBOARD_URL_PATH:-climate-dashboard}"
HA_CLIMATE_DASHBOARD_TITLE="${HA_CLIMATE_DASHBOARD_TITLE:-Indoor Climate}"
HA_CLIMATE_DASHBOARD_ICON="${HA_CLIMATE_DASHBOARD_ICON:-mdi:home-thermometer-outline}"
ZIGBEE_SENSOR_ENTITY_MATCH="${ZIGBEE_SENSOR_ENTITY_MATCH:-3rths24bz}"
FORCE_UPDATE="${FORCE_UPDATE:-0}"

log_info "=============================================="
log_info "STEP 19C - HOME ASSISTANT CLIMATE DASHBOARD"
log_info "=============================================="

[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in awk base64 curl grep python3 qm; do
  command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"
done
[[ -n "${HA_TOKEN}" ]] || die "HA_TOKEN is not set in config/local.conf"
[[ "$(qm status "${HA_VM_ID}")" == "status: running" ]] \
  || die "Home Assistant VM ${HA_VM_ID} is not running"
qm agent "${HA_VM_ID}" ping >/dev/null 2>&1 \
  || die "Home Assistant guest agent does not respond"

ha_ip="$(qm agent "${HA_VM_ID}" network-get-interfaces 2>/dev/null \
  | awk '/"ip-address" :/ {ip=$3; gsub(/[",]/, "", ip)} /"ip-address-type" : "ipv4"/ {if (ip !~ /^(127|169\.254|172\.30)\./) {print ip; exit}}')"
[[ -n "${ha_ip}" ]] || die "Could not detect the Home Assistant LAN IP"

states_json="$(curl -fsS -H "Authorization: Bearer ${HA_TOKEN}" --max-time 15 \
  "http://${ha_ip}:${HA_HTTP_PORT:-8123}/api/states")"

mapfile -t sensor_entities < <(
  SENSOR_STATES="${states_json}" \
  ZIGBEE_SENSOR_ENTITY_MATCH="${ZIGBEE_SENSOR_ENTITY_MATCH}" \
  python3 - <<'PY'
import json
import os

states = json.loads(os.environ["SENSOR_STATES"])
entity_match = os.environ["ZIGBEE_SENSOR_ENTITY_MATCH"].lower()
wanted = ("temperature", "humidity", "battery")
found = {}

for entity in states:
    entity_id = entity.get("entity_id", "")
    if entity_match not in entity_id.lower():
        continue
    device_class = entity.get("attributes", {}).get("device_class")
    if device_class in wanted and entity.get("state") not in {"unknown", "unavailable", None, ""}:
        found[device_class] = entity_id

missing = [device_class for device_class in wanted if device_class not in found]
if missing:
    raise SystemExit("Missing live sensor entities: " + ", ".join(missing))

for device_class in wanted:
    print(found[device_class])
PY
)

temperature_entity="${sensor_entities[0]}"
humidity_entity="${sensor_entities[1]}"
battery_entity="${sensor_entities[2]}"

log_info "Preparing compact native dashboard configuration..."
dashboard_config_b64="$(base64 -w0 <<EOF
{
  "views": [
    {
      "title": "Climate",
      "path": "climate",
      "icon": "mdi:home-thermometer-outline",
      "type": "sections",
      "max_columns": 2,
      "sections": [
        {
          "type": "grid",
          "column_span": 2,
          "cards": [
            {
              "type": "heading",
              "heading": "Indoor climate",
              "icon": "mdi:home-thermometer-outline"
            },
            {
              "type": "sensor",
              "entity": "${temperature_entity}",
              "name": "Temperature",
              "icon": "mdi:thermometer",
              "graph": "line",
              "hours_to_show": 24,
              "detail": 2,
              "grid_options": {
                "columns": 6,
                "rows": 3
              }
            },
            {
              "type": "sensor",
              "entity": "${humidity_entity}",
              "name": "Humidity",
              "icon": "mdi:water-percent",
              "graph": "line",
              "hours_to_show": 24,
              "detail": 2,
              "grid_options": {
                "columns": 6,
                "rows": 3
              }
            },
            {
              "type": "tile",
              "entity": "${battery_entity}",
              "name": "Sensor battery",
              "icon": "mdi:battery",
              "vertical": false,
              "grid_options": {
                "columns": 12,
                "rows": 1
              }
            }
          ]
        },
        {
          "type": "grid",
          "column_span": 2,
          "cards": [
            {
              "type": "heading",
              "heading": "History - last 7 days",
              "icon": "mdi:chart-line"
            },
            {
              "type": "history-graph",
              "title": "Temperature",
              "hours_to_show": 168,
              "entities": [
                "${temperature_entity}"
              ],
              "grid_options": {
                "columns": 6,
                "rows": 4
              }
            },
            {
              "type": "history-graph",
              "title": "Humidity",
              "hours_to_show": 168,
              "entities": [
                "${humidity_entity}"
              ],
              "grid_options": {
                "columns": 6,
                "rows": 4
              }
            }
          ]
        }
      ]
    }
  ]
}
EOF
)"

python_code_b64="$(base64 -w0 <<'PYTHON'
import base64
import json
import os
import sys

import websocket

TOKEN = os.environ["HASS_TOKEN"]
URL_PATH = os.environ["DASHBOARD_URL_PATH"]
TITLE = os.environ["DASHBOARD_TITLE"]
ICON = os.environ["DASHBOARD_ICON"]
FORCE = os.environ.get("FORCE_UPDATE", "0") == "1"
CONFIG = json.loads(base64.b64decode(os.environ["DASHBOARD_CONFIG_B64"]))


def request(ws, message_id, message_type, **payload):
    ws.send(json.dumps({"id": message_id, "type": message_type, **payload}))
    while True:
        response = json.loads(ws.recv())
        if response.get("id") == message_id:
            if not response.get("success"):
                error = response.get("error", {})
                raise RuntimeError(error.get("message", "Home Assistant request failed"))
            return response.get("result")


ws = websocket.create_connection("ws://127.0.0.1:8123/api/websocket", timeout=20)
try:
    if json.loads(ws.recv()).get("type") != "auth_required":
        raise RuntimeError("Home Assistant WebSocket did not request authentication")
    ws.send(json.dumps({"type": "auth", "access_token": TOKEN}))
    if json.loads(ws.recv()).get("type") != "auth_ok":
        raise RuntimeError("Home Assistant WebSocket authentication failed")

    dashboards = request(ws, 1, "lovelace/dashboards/list")
    existing = next((item for item in dashboards if item.get("url_path") == URL_PATH), None)
    if existing and not FORCE:
        print("dashboard_exists=" + URL_PATH)
        sys.exit(0)

    if not existing:
        request(
            ws,
            2,
            "lovelace/dashboards/create",
            url_path=URL_PATH,
            title=TITLE,
            icon=ICON,
            show_in_sidebar=True,
            require_admin=False,
        )
        print("dashboard_created=" + URL_PATH)
    else:
        print("dashboard_update=enabled")

    available = {item.get("entity_id") for item in request(ws, 3, "get_states")}
    required = set()
    for view in CONFIG["views"]:
        for section in view.get("sections", []):
            for card in section.get("cards", []):
                if card.get("entity"):
                    required.add(card["entity"])
                required.update(card.get("entities", []))
    missing = sorted(required - available)
    if missing:
        raise RuntimeError("Dashboard entities not found: " + ", ".join(missing))

    request(ws, 4, "lovelace/config/save", url_path=URL_PATH, config=CONFIG)
    print("dashboard_config_saved=" + URL_PATH)
finally:
    ws.close()
PYTHON
)"

log_info "Creating or checking dashboard '${HA_CLIMATE_DASHBOARD_URL_PATH}'..."
guest_result="$(
  qm guest exec "${HA_VM_ID}" -- /usr/bin/docker exec \
    -e "HASS_TOKEN=${HA_TOKEN}" \
    -e "DASHBOARD_URL_PATH=${HA_CLIMATE_DASHBOARD_URL_PATH}" \
    -e "DASHBOARD_TITLE=${HA_CLIMATE_DASHBOARD_TITLE}" \
    -e "DASHBOARD_ICON=${HA_CLIMATE_DASHBOARD_ICON}" \
    -e "FORCE_UPDATE=${FORCE_UPDATE}" \
    -e "DASHBOARD_CONFIG_B64=${dashboard_config_b64}" \
    -e "PYTHON_CODE_B64=${python_code_b64}" \
    homeassistant python3 -c \
    'import base64,os; exec(compile(base64.b64decode(os.environ["PYTHON_CODE_B64"]), "climate-dashboard.py", "exec"))' \
    2>&1
)"

if grep -q 'dashboard_created=' <<<"${guest_result}"; then
  log_info "Indoor Climate dashboard created"
elif grep -q 'dashboard_exists=' <<<"${guest_result}"; then
  log_info "Indoor Climate dashboard already exists; existing configuration preserved"
elif grep -q 'dashboard_config_saved=' <<<"${guest_result}"; then
  log_info "Indoor Climate dashboard configuration updated"
else
  log_error "Home Assistant dashboard creation failed"
  log_error "$(head -c 800 <<<"${guest_result}")"
  exit 1
fi

log_info "Dashboard URL: /${HA_CLIMATE_DASHBOARD_URL_PATH}"
log_info "Home Assistant climate dashboard completed successfully"
