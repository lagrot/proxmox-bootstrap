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

log_info "=============================================="
log_info "STEP 10M - HOME ASSISTANT FRIGATE DASHBOARD"
log_info "=============================================="

HA_VM_ID="${HA_VM_ID:-100}"
HA_TOKEN="${HA_TOKEN:-}"
HA_DASHBOARD_URL_PATH="${HA_DASHBOARD_URL_PATH:-frigate-dashboard}"
HA_DASHBOARD_TITLE="${HA_DASHBOARD_TITLE:-Frigate}"
HA_DASHBOARD_ICON="${HA_DASHBOARD_ICON:-mdi:cctv}"
FRIGATE_CAMERA_ENTITY="${FRIGATE_CAMERA_ENTITY:-camera.tplink_c200_1}"
FORCE_UPDATE="${FORCE_UPDATE:-0}"

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

if [[ "${EUID}" -ne 0 ]]; then
  record_error "This script must be run as root"
fi

for cmd in qm grep base64; do
  check_host_command "${cmd}"
done

if [[ -z "${HA_TOKEN}" ]]; then
  record_error "HA_TOKEN is not set; add it to config/local.conf"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  exit 1
fi

log_info "Preparing native Frigate dashboard configuration..."
DASHBOARD_CONFIG_B64="$(base64 -w0 <<EOF
{
  "views": [
    {
      "title": "Cameras",
      "path": "cameras",
      "icon": "mdi:cctv",
      "type": "sections",
      "max_columns": 2,
      "sections": [
        {
          "type": "grid",
          "cards": [
            {
              "type": "heading",
              "heading": "Live camera",
              "icon": "mdi:camera-wireless"
            },
            {
              "type": "picture-entity",
              "entity": "${FRIGATE_CAMERA_ENTITY}",
              "camera_view": "live",
              "show_name": true,
              "show_state": true,
              "fit_mode": "cover"
            }
          ]
        },
        {
          "type": "grid",
          "cards": [
            {
              "type": "heading",
              "heading": "Camera controls",
              "icon": "mdi:shield-video"
            },
            {
              "type": "entities",
              "title": "Tapo C200",
              "show_header_toggle": false,
              "entities": [
                "switch.tplink_c200_1_detect",
                "switch.tplink_c200_1_recordings",
                "switch.tplink_c200_1_snapshots",
                "switch.tplink_c200_1_motion",
                "switch.tplink_c200_1_review_alerts",
                "switch.tplink_c200_1_review_detections"
              ]
            }
          ]
        },
        {
          "type": "grid",
          "cards": [
            {
              "type": "heading",
              "heading": "Detection status",
              "icon": "mdi:motion-sensor"
            },
            {
              "type": "entities",
              "entities": [
                "binary_sensor.tplink_c200_1_motion",
                "binary_sensor.tplink_c200_1_person_occupancy",
                "binary_sensor.tplink_c200_1_all_occupancy",
                "sensor.tplink_c200_1_person_count",
                "sensor.tplink_c200_1_all_count",
                "sensor.tplink_c200_1_review_status"
              ]
            }
          ]
        }
      ]
    }
  ]
}
EOF
)"

PYTHON_CODE_B64="$(base64 -w0 <<'PYTHON'
import base64
import json
import os
import sys
import websocket


TOKEN = os.environ["HASS_TOKEN"]
URL_PATH = os.environ["HA_DASHBOARD_URL_PATH"]
TITLE = os.environ["HA_DASHBOARD_TITLE"]
ICON = os.environ["HA_DASHBOARD_ICON"]
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
    hello = json.loads(ws.recv())
    if hello.get("type") != "auth_required":
        raise RuntimeError("Home Assistant WebSocket did not request authentication")

    ws.send(json.dumps({"type": "auth", "access_token": TOKEN}))
    auth = json.loads(ws.recv())
    if auth.get("type") != "auth_ok":
        raise RuntimeError("Home Assistant WebSocket authentication failed")

    dashboards = request(ws, 1, "lovelace/dashboards/list")
    existing = next((item for item in dashboards if item.get("url_path") == URL_PATH), None)

    if existing and not FORCE:
        print("dashboard_exists=" + URL_PATH)
        sys.exit(0)

    if not existing:
        created = request(
            ws,
            2,
            "lovelace/dashboards/create",
            url_path=URL_PATH,
            title=TITLE,
            icon=ICON,
            show_in_sidebar=True,
            require_admin=False,
        )
        print("dashboard_created=" + str(created.get("url_path", URL_PATH)))
    else:
        print("dashboard_update=enabled")

    request(
        ws,
        3,
        "lovelace/config/save",
        url_path=URL_PATH,
        config=CONFIG,
    )
    print("dashboard_config_saved=" + URL_PATH)
finally:
    ws.close()
PYTHON
)"

log_info "Creating or checking dashboard '${HA_DASHBOARD_URL_PATH}'..."
GUEST_RESULT="$(
  qm guest exec "${HA_VM_ID}" -- /usr/bin/docker exec \
    -e "HASS_TOKEN=${HA_TOKEN}" \
    -e "HA_DASHBOARD_URL_PATH=${HA_DASHBOARD_URL_PATH}" \
    -e "HA_DASHBOARD_TITLE=${HA_DASHBOARD_TITLE}" \
    -e "HA_DASHBOARD_ICON=${HA_DASHBOARD_ICON}" \
    -e "FORCE_UPDATE=${FORCE_UPDATE}" \
    -e "DASHBOARD_CONFIG_B64=${DASHBOARD_CONFIG_B64}" \
    -e "PYTHON_CODE_B64=${PYTHON_CODE_B64}" \
    homeassistant python3 -c 'import base64,os; exec(compile(base64.b64decode(os.environ["PYTHON_CODE_B64"]), "frigate-dashboard.py", "exec"))' \
    2>&1
)"

if grep -q 'dashboard_created=' <<< "${GUEST_RESULT}"; then
  log_info "Frigate dashboard created"
elif grep -q 'dashboard_exists=' <<< "${GUEST_RESULT}"; then
  log_info "Frigate dashboard already exists; existing configuration preserved"
elif grep -q 'dashboard_config_saved=' <<< "${GUEST_RESULT}"; then
  log_info "Frigate dashboard configuration updated"
else
  log_error "Home Assistant dashboard creation failed"
  sed -n 's/.*"err-data"[[:space:]]*:[[:space:]]*"\([^"].*\)".*/\1/p' <<< "${GUEST_RESULT}" \
    | sed 's/\\n/ /g; s/\\"/"/g' \
    | head -c 800 \
    | while IFS= read -r line; do log_error "${line}"; done
  exit 1
fi

log_info "Dashboard URL: /${HA_DASHBOARD_URL_PATH}"
log_info "Frigate dashboard completed successfully"
