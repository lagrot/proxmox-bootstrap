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
C200_NAME="${TAPO_C200_NAME:-tplink_c200_1}"
C320WS_NAME="${TAPO_C320WS_NAME:-tplink_c320ws_1}"
FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
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

for cmd in qm pct awk grep base64; do
  check_host_command "${cmd}"
done

if [[ -z "${HA_TOKEN}" ]]; then
  record_error "HA_TOKEN is not set; add it to config/local.conf"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  exit 1
fi

FRIGATE_CT_IP="$(
  pct exec "${FRIGATE_CT_ID}" -- ip -4 -o addr show dev eth0 2>/dev/null \
    | awk '{ split($4, address, "/"); print address[1]; exit }' || true
)"

if [[ -z "${FRIGATE_CT_IP}" ]]; then
  record_error "Could not detect the Frigate CT IPv4 address"
  exit 1
fi

FRIGATE_REVIEW_URL="https://${FRIGATE_CT_IP}:${FRIGATE_WEB_PORT:-8971}/review"

log_info "Preparing native Frigate dashboard configuration..."
DASHBOARD_CONFIG_B64="$(base64 -w0 <<EOF
{
  "views": [
    {
      "title": "Live",
      "path": "live",
      "icon": "mdi:cctv",
      "type": "sections",
      "max_columns": 2,
      "sections": [
        {
          "type": "grid",
          "cards": [
            {
              "type": "heading",
              "heading": "Tapo C200",
              "icon": "mdi:camera-wireless"
            },
            {
              "type": "picture-entity",
              "entity": "camera.${C200_NAME}",
              "camera_view": "live",
              "show_name": true,
              "show_state": true,
              "fit_mode": "cover"
            },
            {
              "type": "tile",
              "entity": "binary_sensor.${C200_NAME}_motion",
              "name": "Motion"
            },
            {
              "type": "tile",
              "entity": "binary_sensor.${C200_NAME}_person_occupancy",
              "name": "Person"
            },
            {
              "type": "tile",
              "entity": "sensor.${C200_NAME}_person_count",
              "name": "People"
            }
          ]
        },
        {
          "type": "grid",
          "cards": [
            {
              "type": "heading",
              "heading": "Tapo C320WS",
              "icon": "mdi:camera-wireless"
            },
            {
              "type": "picture-entity",
              "entity": "camera.${C320WS_NAME}",
              "camera_view": "live",
              "show_name": true,
              "show_state": true,
              "fit_mode": "cover"
            },
            {
              "type": "tile",
              "entity": "binary_sensor.${C320WS_NAME}_motion",
              "name": "Motion"
            },
            {
              "type": "tile",
              "entity": "binary_sensor.${C320WS_NAME}_person_occupancy",
              "name": "Person"
            },
            {
              "type": "tile",
              "entity": "sensor.${C320WS_NAME}_person_count",
              "name": "People"
            }
          ]
        },
        {
          "type": "grid",
          "cards": [
            {
              "type": "heading",
              "heading": "Quick recording controls",
              "icon": "mdi:record-rec"
            },
            {
              "type": "tile",
              "entity": "switch.${C200_NAME}_recordings",
              "name": "C200 recording"
            },
            {
              "type": "tile",
              "entity": "switch.${C320WS_NAME}_recordings",
              "name": "C320WS recording"
            }
          ]
        }
      ]
    },
    {
      "title": "Review",
      "path": "review",
      "icon": "mdi:play-box-multiple",
      "type": "sections",
      "max_columns": 2,
      "sections": [
        {
          "type": "grid",
          "cards": [
            {
              "type": "heading",
              "heading": "Latest C200 person",
              "icon": "mdi:account-search"
            },
            {
              "type": "picture-entity",
              "entity": "image.${C200_NAME}_person",
              "show_name": true,
              "show_state": true,
              "fit_mode": "contain"
            },
            {
              "type": "entities",
              "entities": [
                "sensor.${C200_NAME}_review_status",
                "sensor.${C200_NAME}_person_count",
                "sensor.${C200_NAME}_all_count"
              ]
            }
          ]
        },
        {
          "type": "grid",
          "cards": [
            {
              "type": "heading",
              "heading": "Latest C320WS person",
              "icon": "mdi:account-search"
            },
            {
              "type": "picture-entity",
              "entity": "image.${C320WS_NAME}_person",
              "show_name": true,
              "show_state": true,
              "fit_mode": "contain"
            },
            {
              "type": "entities",
              "entities": [
                "sensor.${C320WS_NAME}_review_status",
                "sensor.${C320WS_NAME}_person_count",
                "sensor.${C320WS_NAME}_all_count"
              ]
            }
          ]
        },
        {
          "type": "grid",
          "cards": [
            {
              "type": "heading",
              "heading": "Recordings and events",
              "icon": "mdi:movie-open"
            },
            {
              "type": "button",
              "name": "Home Assistant media",
              "icon": "mdi:folder-play",
              "tap_action": {
                "action": "navigate",
                "navigation_path": "/media-browser/browser"
              }
            },
            {
              "type": "button",
              "name": "Open Frigate Review",
              "icon": "mdi:cctv",
              "tap_action": {
                "action": "url",
                "url_path": "${FRIGATE_REVIEW_URL}"
              }
            }
          ]
        }
      ]
    },
    {
      "title": "System",
      "path": "system",
      "icon": "mdi:cog-outline",
      "type": "sections",
      "max_columns": 2,
      "sections": [
        {
          "type": "grid",
          "cards": [
            {
              "type": "heading",
              "heading": "C200 advanced controls",
              "icon": "mdi:shield-video"
            },
            {
              "type": "entities",
              "show_header_toggle": false,
              "entities": [
                "switch.${C200_NAME}_detect",
                "switch.${C200_NAME}_motion",
                "switch.${C200_NAME}_snapshots",
                "switch.${C200_NAME}_review_alerts",
                "switch.${C200_NAME}_review_detections"
              ]
            }
          ]
        },
        {
          "type": "grid",
          "cards": [
            {
              "type": "heading",
              "heading": "C320WS advanced controls",
              "icon": "mdi:shield-video"
            },
            {
              "type": "entities",
              "show_header_toggle": false,
              "entities": [
                "switch.${C320WS_NAME}_detect",
                "switch.${C320WS_NAME}_motion",
                "switch.${C320WS_NAME}_snapshots",
                "switch.${C320WS_NAME}_review_alerts",
                "switch.${C320WS_NAME}_review_detections"
              ]
            }
          ]
        },
        {
          "type": "grid",
          "cards": [
            {
              "type": "heading",
              "heading": "Activity - last 24 hours",
              "icon": "mdi:chart-timeline-variant"
            },
            {
              "type": "history-graph",
              "title": "C200 activity",
              "hours_to_show": 24,
              "entities": [
                {
                  "entity": "binary_sensor.${C200_NAME}_motion",
                  "name": "Motion"
                },
                {
                  "entity": "binary_sensor.${C200_NAME}_person_occupancy",
                  "name": "Person"
                }
              ]
            },
            {
              "type": "history-graph",
              "title": "C320WS activity",
              "hours_to_show": 24,
              "entities": [
                {
                  "entity": "binary_sensor.${C320WS_NAME}_motion",
                  "name": "Motion"
                },
                {
                  "entity": "binary_sensor.${C320WS_NAME}_person_occupancy",
                  "name": "Person"
                }
              ]
            }
          ]
        },
        {
          "type": "grid",
          "cards": [
            {
              "type": "heading",
              "heading": "Camera diagnostics",
              "icon": "mdi:heart-pulse"
            },
            {
              "type": "entities",
              "entities": [
                "camera.${C200_NAME}",
                "sensor.${C200_NAME}_review_status",
                "camera.${C320WS_NAME}",
                "sensor.${C320WS_NAME}_review_status"
              ]
            },
            {
              "type": "button",
              "name": "Open Frigate",
              "icon": "mdi:open-in-new",
              "tap_action": {
                "action": "url",
                "url_path": "https://${FRIGATE_CT_IP}:${FRIGATE_WEB_PORT:-8971}"
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

    states = request(ws, 3, "get_states")
    available_entities = {item.get("entity_id") for item in states}

    def collect_entities(value):
        found = set()
        if isinstance(value, dict):
            entity = value.get("entity")
            if isinstance(entity, str):
                found.add(entity)
            entities = value.get("entities")
            if isinstance(entities, list):
                found.update(item for item in entities if isinstance(item, str))
            for child in value.values():
                found.update(collect_entities(child))
        elif isinstance(value, list):
            for child in value:
                found.update(collect_entities(child))
        return found

    required_entities = collect_entities(CONFIG)
    missing_entities = sorted(required_entities - available_entities)
    if missing_entities:
        raise RuntimeError("Dashboard entities not found: " + ", ".join(missing_entities))
    print("dashboard_entities_validated=" + str(len(required_entities)))

    request(
        ws,
        4,
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
