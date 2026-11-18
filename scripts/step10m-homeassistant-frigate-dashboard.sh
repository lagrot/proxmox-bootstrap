#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

MODE="apply"
if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [--dry-run]\n' "$0" >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
    --dry-run) MODE="dry-run"; LOG_FILE=/dev/null ;;
    --help|-h) printf 'Usage: %s [--dry-run]\n' "$0"; exit 0 ;;
    *) printf 'Unknown argument: %s\nUsage: %s [--dry-run]\n' "$1" "$0" >&2; exit 2 ;;
  esac
fi

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
FRIGATE_WEB_PORT="${FRIGATE_WEB_PORT:-8971}"

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

if [[ "${MODE}" == "apply" && "${EUID}" -ne 0 ]]; then
  record_error "This script must be run as root"
fi

if [[ ! "${HA_VM_ID}" =~ ^[1-9][0-9]{2,8}$ ]]; then
  record_error "HA_VM_ID must be a Proxmox VM ID of 100 or greater"
fi
if [[ ! "${FRIGATE_CT_ID}" =~ ^[1-9][0-9]{2,8}$ ]]; then
  record_error "DOCKER_CT_ID must be a Proxmox CT ID of 100 or greater"
fi
if [[ ! "${HA_DASHBOARD_URL_PATH}" =~ ^[a-z0-9][a-z0-9_-]{0,39}$ ]]; then
  record_error "HA_DASHBOARD_URL_PATH must be a lowercase URL slug (letters, digits, _ or -)"
fi
HA_DASHBOARD_TITLE_RE='^[A-Za-z0-9][A-Za-z0-9 _-]{0,39}$'
if [[ ! "${HA_DASHBOARD_TITLE}" =~ ${HA_DASHBOARD_TITLE_RE} ]]; then
  record_error "HA_DASHBOARD_TITLE must be 1-40 simple letters, digits, spaces, _ or -"
fi
if [[ ! "${HA_DASHBOARD_ICON}" =~ ^mdi:[a-z0-9-]+$ ]]; then
  record_error "HA_DASHBOARD_ICON must use the mdi:name format"
fi
if [[ ! "${C200_NAME}" =~ ^[a-z0-9_]+$ || ! "${C320WS_NAME}" =~ ^[a-z0-9_]+$ ]]; then
  record_error "Camera names must contain only lowercase letters, digits, and underscores"
fi
if [[ "${C200_NAME}" == "${C320WS_NAME}" ]]; then
  record_error "The C200 and C320WS camera names must be different"
fi
if [[ ! "${FRIGATE_WEB_PORT}" =~ ^[0-9]{1,5}$ ]] \
  || ((10#${FRIGATE_WEB_PORT:-0} < 1 || 10#${FRIGATE_WEB_PORT:-0} > 65535)); then
  record_error "FRIGATE_WEB_PORT must be an integer from 1 through 65535"
fi
if [[ "${FORCE_UPDATE}" != "0" && "${FORCE_UPDATE}" != "1" ]]; then
  record_error "FORCE_UPDATE must be 0 or 1"
fi

if [[ "${MODE}" == "dry-run" ]]; then
  if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
    exit 1
  fi
  log_info "Dry run: no Proxmox guest or Home Assistant API calls will be made"
  log_info "Would validate Frigate dashboard entities, then create or preserve /${HA_DASHBOARD_URL_PATH}"
  if [[ "${FORCE_UPDATE}" == "1" ]]; then
    log_info "Would replace the existing dashboard configuration because FORCE_UPDATE=1"
  else
    log_info "Would preserve an existing dashboard at /${HA_DASHBOARD_URL_PATH}"
  fi
  log_info "No changes were made"
  exit 0
fi

for cmd in qm pct grep sed head base64 python3; do
  check_host_command "${cmd}"
done

if [[ -z "${HA_TOKEN}" ]]; then
  record_error "HA_TOKEN is not set; add it to config/local.conf"
fi
export -n HA_TOKEN

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  exit 1
fi

FRIGATE_INTERFACE_JSON="$(pct exec "${FRIGATE_CT_ID}" -- ip -j -4 addr show dev eth0 2>/dev/null || true)"
FRIGATE_CT_IP="$(FRIGATE_INTERFACE_JSON="${FRIGATE_INTERFACE_JSON}" python3 - <<'PY'
import ipaddress
import json
import os

try:
    interfaces = json.loads(os.environ["FRIGATE_INTERFACE_JSON"])
except (json.JSONDecodeError, KeyError):
    raise SystemExit(0)
for interface in interfaces if isinstance(interfaces, list) else []:
    for item in interface.get("addr_info", []):
        if item.get("family") != "inet":
            continue
        try:
            address = ipaddress.IPv4Address(item.get("local", ""))
        except ipaddress.AddressValueError:
            continue
        if address.is_loopback or address.is_link_local or address.is_unspecified or address.is_multicast:
            continue
        print(address)
        raise SystemExit(0)
PY
)"

if [[ -z "${FRIGATE_CT_IP}" ]]; then
  record_error "Could not detect the Frigate CT IPv4 address"
  exit 1
fi

FRIGATE_REVIEW_URL="https://${FRIGATE_CT_IP}:${FRIGATE_WEB_PORT}/review"

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

PYTHON_CODE_B64="$(base64 -w0 < "${PROJECT_ROOT}/scripts/step10m-homeassistant-frigate-dashboard-client.py")"

log_info "Creating or checking dashboard '${HA_DASHBOARD_URL_PATH}'..."
if ! GUEST_RESULT="$(
  printf '%s' "${HA_TOKEN}" \
    | python3 -c 'import json,sys; print(json.dumps({"token":sys.stdin.read()}), end="")' \
    | qm guest exec "${HA_VM_ID}" --pass-stdin -- /usr/bin/docker exec -i \
      -e "HA_DASHBOARD_URL_PATH=${HA_DASHBOARD_URL_PATH}" \
      -e "HA_DASHBOARD_TITLE=${HA_DASHBOARD_TITLE}" \
      -e "HA_DASHBOARD_ICON=${HA_DASHBOARD_ICON}" \
      -e "FORCE_UPDATE=${FORCE_UPDATE}" \
      -e "DASHBOARD_CONFIG_B64=${DASHBOARD_CONFIG_B64}" \
      -e "PYTHON_CODE_B64=${PYTHON_CODE_B64}" \
      homeassistant python3 -c 'import base64,os; exec(compile(base64.b64decode(os.environ["PYTHON_CODE_B64"]), "frigate-dashboard.py", "exec"))' \
      2>&1
)"; then
  log_error "Home Assistant guest-agent dashboard command failed"
  exit 1
fi

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
