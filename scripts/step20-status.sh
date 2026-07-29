#!/usr/bin/env bash
set -euo pipefail

STATUS_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${STATUS_SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

[[ "${EUID}" -eq 0 ]] || { printf 'ERROR: Run as root\n' >&2; exit 1; }
for cmd in date grep pct python3 systemctl; do
  command -v "${cmd}" >/dev/null || { printf 'ERROR: Missing command: %s\n' "${cmd}" >&2; exit 1; }
done
[[ -f "${UPDATE_STATUS_FILE}" ]] \
  || { printf 'ERROR: No update audit status. Run: bash scripts/step20a-update-audit.sh\n' >&2; exit 1; }
python3 -m json.tool "${UPDATE_STATUS_FILE}" >/dev/null \
  || { printf 'ERROR: Update audit status is invalid\n' >&2; exit 1; }

mapfile -t audit < <(python3 - "${UPDATE_STATUS_FILE}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
updates = data.get("package_updates", {})
print(data.get("completed_at", "unknown"))
print(data.get("status", "unknown").upper())
print("READY" if data.get("backup_ready") else "NOT READY")
print("Yes" if data.get("host_reboot_required") else "No")
for key in ("proxmox_host", "ct200", "ct210", "ct220"):
    item = updates.get(key, {})
    print(f'{item.get("total", 0)}\t{item.get("debian_security", 0)}')
PY
)

audit_completed="${audit[0]}"
audit_completed_display="$(date '+%Y-%m-%d %H:%M %Z' -d "${audit_completed}" 2>/dev/null || printf '%s' "${audit_completed}")"
audit_result="${audit[1]}"
backup_ready="${audit[2]}"
host_reboot="${audit[3]}"
read -r host_updates host_security <<<"${audit[4]}"
read -r ct200_updates ct200_security <<<"${audit[5]}"
read -r ct210_updates ct210_security <<<"${audit[6]}"
read -r ct220_updates ct220_security <<<"${audit[7]}"

backup_path="unavailable"
backup_time="unknown"
if [[ -f "${BACKUP_LAST_SUCCESS_FILE}" ]]; then
  backup_path="$(<"${BACKUP_LAST_SUCCESS_FILE}")"
  [[ -f "${backup_path}/.validated" ]] \
    && backup_time="$(date '+%Y-%m-%d %H:%M %Z' -r "${backup_path}/.validated")"
fi

reboot_state() {
  local ct_id="$1"
  if ! pct status "${ct_id}" 2>/dev/null | grep -q 'status: running'; then
    printf 'Unknown'
  elif pct exec "${ct_id}" -- test -e /var/run/reboot-required 2>/dev/null; then
    printf 'Yes'
  else
    printf 'No'
  fi
}

ct200_reboot="$(reboot_state "${DOCKER_CT_ID:-200}")"
ct210_reboot="$(reboot_state "${MQTT_CT_ID:-210}")"
ct220_reboot="$(reboot_state "${HERMES_CT_ID:-220}")"

next_timer() {
  local unit="$1" value
  value="$(systemctl show "${unit}" -p NextElapseUSecRealtime --value 2>/dev/null || true)"
  [[ -n "${value}" ]] && printf '%s' "${value}" || printf 'not scheduled'
}

auto_security_state() {
  local ct_id="$1"
  if pct exec "${ct_id}" -- dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null \
      | grep -qx 'install ok installed' \
    && pct exec "${ct_id}" -- systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null \
    && pct exec "${ct_id}" -- test -f /etc/apt/apt.conf.d/52homelab-unattended-upgrades 2>/dev/null; then
    printf 'ENABLED'
  else
    printf 'NOT SET'
  fi
}

ct200_auto="$(auto_security_state "${DOCKER_CT_ID:-200}")"
ct210_auto="$(auto_security_state "${MQTT_CT_ID:-210}")"
ct220_auto="$(auto_security_state "${HERMES_CT_ID:-220}")"

printf '\nUPDATE OPERATIONS STATUS\n'
printf '%s\n' '========================'
printf '%-20s %s\n' "Last audit:" "${audit_completed_display}"
printf '%-20s %s\n' "Audit result:" "${audit_result}"
printf '%-20s %s\n' "Backup gate:" "${backup_ready}"
printf '%-20s %s\n' "Last backup:" "${backup_time}"
printf '%-20s %s\n' "Backup path:" "${backup_path}"

printf '\n%-12s %10s %10s %10s %14s\n' "System" "Updates" "Security" "Reboot" "Auto-security"
printf '%-12s %10s %10s %10s %14s\n' "Proxmox" "${host_updates}" "${host_security}" "${host_reboot}" "MANUAL"
printf '%-12s %10s %10s %10s %14s\n' "CT 200" "${ct200_updates}" "${ct200_security}" "${ct200_reboot}" "${ct200_auto}"
printf '%-12s %10s %10s %10s %14s\n' "CT 210" "${ct210_updates}" "${ct210_security}" "${ct210_reboot}" "${ct210_auto}"
printf '%-12s %10s %10s %10s %14s\n' "CT 220" "${ct220_updates}" "${ct220_security}" "${ct220_reboot}" "${ct220_auto}"

printf '\nSCHEDULE\n'
printf '%-20s %s\n' "Next backup:" "$(next_timer proxmox-bootstrap-backup.timer)"
printf '%-20s %s\n' "Next audit:" "$(next_timer proxmox-bootstrap-update-audit.timer)"

printf '\nOPERATING GUIDANCE\n'
if [[ "${audit_result}" != "SUCCESS" || "${backup_ready}" != "READY" ]]; then
  printf 'Resolve the failed audit or backup gate.\n'
  printf 'Run: bash scripts/step20a-update-audit.sh\n'
elif [[ "${ct200_auto}" != ENABLED || "${ct210_auto}" != ENABLED || "${ct220_auto}" != ENABLED ]]; then
  printf 'Automatic CT security updates are not fully configured.\n'
  printf 'Review: bash scripts/step20f-unattended-upgrades.sh --dry-run\n'
  printf 'Enable: bash scripts/step20f-unattended-upgrades.sh --confirm-install\n'
else
  printf 'Debian security updates for CT 200, CT 210, and CT 220 are automatic.\n'
  printf 'No weekly patch action is required.\n'
  if (( host_updates > 0 )); then
    printf 'Proxmox has %d update(s), %d security-related; review during monthly host maintenance.\n' \
      "${host_updates}" "${host_security}"
  fi
fi
printf '\n'
