#!/usr/bin/env bash
set -euo pipefail

STATUS_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${STATUS_SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

UPDATE_TRANSACTION_ROOT="${UPDATE_TRANSACTION_ROOT:-/var/lib/proxmox-bootstrap/update-transactions}"
UPDATE_SNAPSHOT_PREFIX="${UPDATE_SNAPSHOT_PREFIX:-pbupd}"

[[ "${EUID}" -eq 0 ]] || { printf 'ERROR: Run as root\n' >&2; exit 1; }
for cmd in awk date find grep pct python3 sort systemctl tail; do
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

managed_snapshots() {
  local ct_id="$1"
  pct listsnapshot "${ct_id}" 2>/dev/null \
    | awk -v prefix="${UPDATE_SNAPSHOT_PREFIX}-" '$2 ~ ("^" prefix) {items = items (items ? ", " : "") $2; count++} END {if (count) print count " (" items ")"; else print "0"}'
}

latest_transaction="none"
latest_transaction_status="none"
if [[ -d "${UPDATE_TRANSACTION_ROOT}" ]]; then
  latest_dir="$(find "${UPDATE_TRANSACTION_ROOT}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -1)"
  if [[ -n "${latest_dir}" && -f "${UPDATE_TRANSACTION_ROOT}/${latest_dir}/status.json" ]]; then
    latest_transaction="${latest_dir}"
    latest_transaction_status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status","unknown"))' \
      "${UPDATE_TRANSACTION_ROOT}/${latest_dir}/status.json")"
  fi
fi

printf '\nUPDATE OPERATIONS STATUS\n'
printf '%s\n' '========================'
printf '%-20s %s\n' "Last audit:" "${audit_completed_display}"
printf '%-20s %s\n' "Audit result:" "${audit_result}"
printf '%-20s %s\n' "Backup gate:" "${backup_ready}"
printf '%-20s %s\n' "Last backup:" "${backup_time}"
printf '%-20s %s\n' "Backup path:" "${backup_path}"

printf '\n%-12s %10s %10s %10s %12s\n' "System" "Updates" "Security" "Reboot" "Snapshots"
printf '%-12s %10s %10s %10s %12s\n' "Proxmox" "${host_updates}" "${host_security}" "${host_reboot}" "-"
printf '%-12s %10s %10s %10s %12s\n' "CT 200" "${ct200_updates}" "${ct200_security}" "${ct200_reboot}" "$(managed_snapshots "${DOCKER_CT_ID:-200}")"
printf '%-12s %10s %10s %10s %12s\n' "CT 210" "${ct210_updates}" "${ct210_security}" "${ct210_reboot}" "$(managed_snapshots "${MQTT_CT_ID:-210}")"
printf '%-12s %10s %10s %10s %12s\n' "CT 220" "${ct220_updates}" "${ct220_security}" "${ct220_reboot}" "$(managed_snapshots "${HERMES_CT_ID:-220}")"

printf '\nSCHEDULE\n'
printf '%-20s %s\n' "Next backup:" "$(next_timer proxmox-bootstrap-backup.timer)"
printf '%-20s %s\n' "Next audit:" "$(next_timer proxmox-bootstrap-update-audit.timer)"

printf '\nLATEST MAINTENANCE\n'
printf '%-20s %s\n' "Transaction:" "${latest_transaction}"
printf '%-20s %s\n' "Result:" "${latest_transaction_status}"

printf '\nRECOMMENDED ACTION\n'
if [[ "${audit_result}" != "SUCCESS" || "${backup_ready}" != "READY" ]]; then
  printf 'Resolve the failed audit or backup gate before maintenance.\n'
  printf 'Run: bash scripts/step20a-update-audit.sh\n'
elif (( ct210_security > 0 )); then
  printf 'CT 210 has %d security-related update(s).\n' "${ct210_security}"
  printf 'Run: bash scripts/step20f-update-target.sh ct210 --dry-run\n'
elif (( ct220_security > 0 )); then
  printf 'CT 220 has %d security-related update(s).\n' "${ct220_security}"
  printf 'Run: bash scripts/step20f-update-target.sh ct220 --dry-run\n'
elif (( ct200_security > 0 )); then
  printf 'CT 200 has %d security-related update(s).\n' "${ct200_security}"
  printf 'Run: bash scripts/step20f-update-target.sh ct200 --dry-run\n'
elif (( host_security > 0 )); then
  printf 'The Proxmox host has %d security-related update(s); plan separate host maintenance.\n' "${host_security}"
elif (( ct210_updates + ct220_updates + ct200_updates + host_updates > 0 )); then
  printf 'Ordinary stable updates are available; schedule maintenance when convenient.\n'
else
  printf 'No pending package updates were reported by the latest audit.\n'
fi
printf '\n'
