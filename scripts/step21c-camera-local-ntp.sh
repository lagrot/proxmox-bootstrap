#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

usage() {
  echo 'Usage: step21c-camera-local-ntp.sh --dry-run | --apply | --validate | --rollback'
  echo 'Manage camera-only NTP access to existing host Chrony. Does not change cameras.'
}
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
case "$1" in
  --help) usage; exit 0 ;;
  --dry-run|--apply|--validate|--rollback) MODE="$1" ;;
  *) die "Unknown argument: $1" ;;
esac
[[ ${EUID} -eq 0 && "$(hostname -s)" == nad9-1 ]] || die 'Run as root on nad9-1'
for cmd in chronyd chronyc ip python3 systemctl ss flock; do
  command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"
done
C200="${TAPO_C200_IP:-${TAPO_CAMERA_IP:-}}"
C320="${TAPO_C320WS_IP:-}"
python3 - "${C200}" "${C320}" <<'PY'
import ipaddress, sys
a = [ipaddress.IPv4Address(x) for x in sys.argv[1:]]
assert len(set(a)) == 2 and all(x.is_private and not x.is_loopback and not x.is_multicast and not x.is_unspecified for x in a), 'Expected two distinct private camera addresses'
PY
SERVER="$(ip -j route get "${C200}" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["prefsrc"])')"
OTHER="$(ip -j route get "${C320}" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["prefsrc"])')"
[[ "${SERVER}" == "${OTHER}" ]] || die 'Cameras use different host source addresses'
MANAGED=/etc/chrony/conf.d/proxmox-bootstrap-camera-ntp.conf
DESIRED="# Managed by proxmox-bootstrap step21c-camera-local-ntp.sh
bindaddress ${SERVER}
bindaddress ::1
allow ${C200}/32
allow ${C320}/32"
systemctl is-active --quiet chrony || die 'Existing Chrony service must be active'

validate() {
  local attempt actual expected
  actual="$(chronyd -p -f /etc/chrony/chrony.conf | grep -Ei '^(allow|deny|bindaddress|binddevice|port|peer|broadcast)[[:space:]]' | sort)"
  expected="$(printf '%s\n' "${DESIRED}" | sed '/^#/d' | sort)"
  [[ "${actual}" == "${expected}" ]] || die 'Effective NTP server directives differ from the camera-only policy'
  for ((attempt=0; attempt<30; attempt++)); do
    if chronyc tracking | grep -Eq '^Leap status[[:space:]]*:[[:space:]]*Normal'; then break; fi
    sleep 2
  done
  (( attempt < 30 )) || die 'Host is not synchronized'
  chronyc accheck "${C200}" | grep -q '^208 ' || die 'C200 NTP access is not allowed'
  chronyc accheck "${C320}" | grep -q '^208 ' || die 'C320WS NTP access is not allowed'
  chronyc accheck 192.0.2.1 | grep -q '^209 ' || die 'Unrelated NTP clients must be denied'
  ss -H -lun 'sport = :123' | grep -Fq "${SERVER}:123" || die 'LAN NTP socket is absent'
  log_info "Host synchronized; NTP at ${SERVER}:123 allows only configured cameras"
}

if [[ "${MODE}" == --validate ]]; then
  [[ -f "${MANAGED}" && "$(cat "${MANAGED}")" == "${DESIRED}" ]] || die 'Managed configuration does not match'
  validate
  exit 0
fi
if [[ "${MODE}" == --dry-run ]]; then
  log_info "Would serve NTP on ${SERVER}:123 for C200 ${C200} and C320WS ${C320} only"
  printf '%s\n' "${DESIRED}"
  [[ ! -e "${MANAGED}" ]] || log_info 'Managed file exists; apply will verify it'
  log_info 'Apply changes only a Chrony drop-in, validates configuration, and restarts Chrony if needed'
  exit 0
fi
exec 9>/run/lock/proxmox-bootstrap-camera-ntp.lock
flock -n 9 || die 'Another camera NTP operation is running'
if [[ -e "${MANAGED}" ]]; then
  [[ ! -L "${MANAGED}" && "$(cat "${MANAGED}")" == "${DESIRED}" ]] || die 'Refusing to replace an unexpected managed file'
  if [[ "${MODE}" == --apply ]]; then validate; log_info 'Already configured; no restart needed'; exit 0; fi
elif [[ "${MODE}" == --rollback ]]; then
  log_info 'Managed file is absent; nothing to roll back'
  exit 0
fi

# Keep parser input inside Chrony's AppArmor-readable tree, outside *.conf includes.
temporary="$(mktemp /etc/chrony/.pb-camera-ntp.XXXXXX)"
changed=0
cleanup() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 && changed == 1 )); then
    if [[ "${MODE}" == --apply ]]; then rm -f -- "${MANAGED}";
    else install -m 0644 "${temporary}" "${MANAGED}"; fi
    systemctl restart chrony || log_error 'Chrony recovery failed; inspect service immediately'
  fi
  rm -f -- "${temporary}"
  exit "${rc}"
}
trap cleanup EXIT
if [[ "${MODE}" == --rollback ]]; then
  cp -- "${MANAGED}" "${temporary}"
  changed=1
  rm -- "${MANAGED}"
else
  grep -Eq '^[[:space:]]*confdir[[:space:]]+/etc/chrony/conf.d([[:space:]]|$)' /etc/chrony/chrony.conf \
    || die 'Chrony does not include the expected drop-in directory'
  effective="$(chronyd -p -f /etc/chrony/chrony.conf)"
  if grep -Eiq '^(allow|deny|bindaddress|binddevice|port|peer|broadcast)[[:space:]]' <<<"${effective}"; then
    die 'Existing NTP server directives require manual review'
  fi
  printf '%s\n%s\n' "${effective}" "${DESIRED}" >"${temporary}"
  # chronyd drops privileges even for parsing; this candidate contains no secrets.
  chmod 0644 "${temporary}"
  chronyd -p -f "${temporary}" >/dev/null
  printf '%s\n' "${DESIRED}" >"${temporary}"
  changed=1
  install -m 0644 "${temporary}" "${MANAGED}"
fi
chronyd -p -f /etc/chrony/chrony.conf >/dev/null
systemctl restart chrony
if [[ "${MODE}" == --apply ]]; then validate; else systemctl is-active --quiet chrony; fi
changed=0
log_info "Host NTP ${MODE} completed; camera settings are unchanged"
