#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
usage() {
  echo 'Usage: step21d-camera-ntp.sh --inspect|--dry-run|--apply|--validate|--validate-sync|--rollback c200|c320ws'
  echo '       step21d-camera-ntp.sh --apply-reboot c200|c320ws  (explicit one-camera reboot)'
  echo 'Manage one camera NTP setting over local ONVIF; credentials come from config/local.conf.'
}
[[ "${1:-}" != --help ]] || { usage; exit 0; }
[[ $# -eq 2 ]] || { usage >&2; exit 2; }
case "$1" in --inspect|--dry-run|--apply|--apply-reboot|--validate|--validate-sync|--rollback) ;; *) usage >&2; exit 2 ;; esac
case "$2" in c200|c320ws) ;; *) usage >&2; exit 2 ;; esac
[[ ${EUID} -eq 0 ]] || { echo 'Run as root on nad9-1' >&2; exit 1; }
set -a
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"
set +a
if [[ "$2" == c200 ]]; then CAMERA_IP="${TAPO_C200_IP:-${TAPO_CAMERA_IP:-}}";
else CAMERA_IP="${TAPO_C320WS_IP:-}"; fi
[[ -n "${CAMERA_IP}" ]] || { echo 'Camera IP is missing' >&2; exit 1; }
NTP_SERVER="$(ip -j route get "${CAMERA_IP}" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["prefsrc"])')"
if [[ "$1" == --apply || "$1" == --apply-reboot || "$1" == --validate-sync ]]; then bash "${PROJECT_ROOT}/scripts/step21c-camera-local-ntp.sh" --validate; fi
if [[ "$1" == --apply || "$1" == --apply-reboot || "$1" == --rollback ]]; then
  exec 9>/run/lock/proxmox-bootstrap-camera-ntp.lock
  flock -n 9 || { echo 'Another camera NTP operation is running' >&2; exit 1; }
fi
python3 -u "${PROJECT_ROOT}/lib/camera_ntp.py" "$1" "$2" "${NTP_SERVER}"
