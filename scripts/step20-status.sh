#!/usr/bin/env bash
set -euo pipefail

STATUS_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${STATUS_SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

[[ "${EUID}" -eq 0 ]] || { printf 'ERROR: Run as root\n' >&2; exit 1; }
for cmd in date pct python3 sha256sum systemctl; do
  command -v "${cmd}" >/dev/null || {
    printf 'ERROR: Missing command: %s\n' "${cmd}" >&2
    exit 1
  }
done
[[ -f "${UPDATE_STATUS_FILE}" ]] || {
  printf 'ERROR: No update audit status. Run: bash scripts/step20a-update-audit.sh\n' >&2
  exit 1
}
python3 -m json.tool "${UPDATE_STATUS_FILE}" >/dev/null || {
  printf 'ERROR: Update audit status is invalid\n' >&2
  exit 1
}

mapfile -t audit < <(python3 - "${UPDATE_STATUS_FILE}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
updates = data.get("package_updates", {})
print(data.get("completed_at", "unknown"))
print(data.get("status", "unknown").upper())
print("Yes" if data.get("host_reboot_required") else "No")
for key in ("proxmox_host", "ct200", "ct210", "ct220"):
    item = updates.get(key, {})
    print(f'{item.get("total", 0)}\t{item.get("debian_security", 0)}')
PY
)

audit_completed="${audit[0]}"
audit_completed_display="$(
  date '+%Y-%m-%d %H:%M %Z' -d "${audit_completed}" 2>/dev/null \
    || printf '%s' "${audit_completed}"
)"
audit_result="${audit[1]}"
host_reboot="${audit[2]}"
read -r host_updates host_security <<<"${audit[3]}"
read -r ct200_updates ct200_security <<<"${audit[4]}"
read -r ct210_updates ct210_security <<<"${audit[5]}"
read -r ct220_updates ct220_security <<<"${audit[6]}"

backup_path="unavailable"
backup_time="unknown"
backup_state="MISSING"
if [[ -f "${BACKUP_LAST_SUCCESS_FILE}" ]]; then
  backup_path="$(<"${BACKUP_LAST_SUCCESS_FILE}")"
  if [[ -f "${backup_path}/.validated" ]]; then
    backup_time="$(date '+%Y-%m-%d %H:%M %Z' -r "${backup_path}/.validated")"
    backup_age="$(( $(date +%s) - $(stat -c %Y "${backup_path}/.validated") ))"
    if (( backup_age <= UPDATE_MAX_BACKUP_AGE_DAYS * 86400 )); then
      backup_state="CURRENT"
    else
      backup_state="STALE"
    fi
  fi
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

next_host_timer() {
  local unit="$1" value
  value="$(systemctl show "${unit}" -p NextElapseUSecRealtime --value 2>/dev/null || true)"
  [[ -n "${value}" ]] && printf '%s' "${value}" || printf 'not scheduled'
}

managed_snapshot_details() {
  local target="$1" ct_id="$2"
  local state_dir state_file saved_target saved_ct snapshot created_epoch result
  local cleanup_epoch cleanup_display
  state_dir="${SECURITY_UPDATE_STATE_DIR:-/var/lib/proxmox-bootstrap/security-updates}"
  state_file="${state_dir}/${target}.state"
  [[ -f "${state_file}" ]] || return 1

  saved_target="$(awk -F= '$1 == "target" {print $2; exit}' "${state_file}")"
  saved_ct="$(awk -F= '$1 == "ct_id" {print $2; exit}' "${state_file}")"
  snapshot="$(awk -F= '$1 == "snapshot" {print $2; exit}' "${state_file}")"
  created_epoch="$(awk -F= '$1 == "created_epoch" {print $2; exit}' "${state_file}")"
  result="$(awk -F= '$1 == "result" {print $2; exit}' "${state_file}")"

  if [[ "${saved_target}" != "${target}" || "${saved_ct}" != "${ct_id}" \
      || ! "${created_epoch}" =~ ^[0-9]+$ \
      || "${snapshot}" != pbsec-*"-${target}" ]]; then
    printf 'CT %s: STATE ERROR | inspect %s\n' "${ct_id}" "${state_file}"
    return 0
  fi
  if ! pct listsnapshot "${ct_id}" 2>/dev/null \
      | awk '$2 != "current" {print $2}' | grep -Fxq "${snapshot}"; then
    printf 'CT %s: STATE ERROR | recorded snapshot is missing\n' "${ct_id}"
    return 0
  fi
  if [[ "${result}" != "success" ]]; then
    printf 'CT %s: UPDATE FAILED | snapshot retained; inspect before rollback\n' "${ct_id}"
    return 0
  fi

  cleanup_epoch="$((created_epoch + 86400))"
  cleanup_display="$(date '+%Y-%m-%d %H:%M %Z' -d "@${cleanup_epoch}")"
  if (( $(date +%s) < cleanup_epoch )); then
    printf 'CT %s: SNAPSHOT RETAINED | cleanup after %s\n' \
      "${ct_id}" "${cleanup_display}"
  else
    printf 'CT %s: CLEANUP DUE | bash scripts/step20-update-ct.sh %s --cleanup\n' \
      "${ct_id}" "${target}"
  fi
}

controlled_security_details() {
  local target="$1" ct_id="$2"
  local local_hash remote_hash local_periodic_hash remote_periodic_hash
  local effective_policy origin_count allowed_count
  local_hash="$(sha256sum "${PROJECT_ROOT}/config/52homelab-unattended-upgrades" | awk '{print $1}')"
  local_periodic_hash="$(sha256sum "${PROJECT_ROOT}/config/20homelab-auto-upgrades" | awk '{print $1}')"
  remote_hash="$(
    pct exec "${ct_id}" -- sha256sum \
      /etc/apt/apt.conf.d/52homelab-unattended-upgrades 2>/dev/null \
      | awk '{print $1}' || true
  )"
  remote_periodic_hash="$(
    pct exec "${ct_id}" -- sha256sum \
      /etc/apt/apt.conf.d/20homelab-auto-upgrades 2>/dev/null \
      | awk '{print $1}' || true
  )"
  effective_policy="$(pct exec "${ct_id}" -- apt-config dump 2>/dev/null || true)"
  origin_count="$(
    grep -c '^Unattended-Upgrade::Origins-Pattern:: "' <<<"${effective_policy}" || true
  )"
  allowed_count="$(
    grep -c '^Unattended-Upgrade::Allowed-Origins:: "' <<<"${effective_policy}" || true
  )"

  if ! pct status "${ct_id}" 2>/dev/null | grep -q 'status: running'; then
    printf 'CT %s: UNAVAILABLE | container is not running\n' "${ct_id}"
    return
  fi
  if ! pct exec "${ct_id}" -- dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null \
      | grep -qx 'install ok installed' \
    || pct exec "${ct_id}" -- systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null \
    || pct exec "${ct_id}" -- systemctl is-active --quiet apt-daily-upgrade.timer 2>/dev/null \
    || [[ "${remote_hash}" != "${local_hash}" ]] \
    || [[ "${remote_periodic_hash}" != "${local_periodic_hash}" ]] \
    || [[ "${origin_count}" != "2" || "${allowed_count}" != "0" ]] \
    || ! grep -Fq 'APT::Periodic::Unattended-Upgrade "0";' <<<"${effective_policy}" \
    || ! grep -Fq 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"${effective_policy}" \
    || pct exec "${ct_id}" -- systemctl is-enabled --quiet systemd-networkd.socket 2>/dev/null \
    || ! pct exec "${ct_id}" -- timeout 5 /usr/lib/apt/apt-helper wait-online >/dev/null 2>&1; then
    printf 'CT %s: NOT CONFIGURED\n' "${ct_id}"
    return
  fi

  if ! managed_snapshot_details "${target}" "${ct_id}"; then
    printf 'CT %s: READY | automatic installation disabled\n' "${ct_id}"
  fi
}

ct200_reboot="$(reboot_state "${DOCKER_CT_ID:-200}")"
ct210_reboot="$(reboot_state "${MQTT_CT_ID:-210}")"
ct220_reboot="$(reboot_state "${HERMES_CT_ID:-220}")"

controlled_lines="$(
  controlled_security_details ct200 "${DOCKER_CT_ID:-200}"
  controlled_security_details ct210 "${MQTT_CT_ID:-210}"
  controlled_security_details ct220 "${HERMES_CT_ID:-220}"
)"

printf '\nUPDATE OPERATIONS STATUS\n'
printf '%s\n' '========================'
printf '%-24s %s\n' "Last weekly audit:" "${audit_completed_display}"
printf '%-24s %s\n' "Audit result:" "${audit_result}"
printf '%-24s %s\n' "Latest validated backup:" "${backup_state}"
printf '%-24s %s\n' "Backup created:" "${backup_time}"
printf '%-24s %s\n' "Backup location:" "${backup_path}"

printf '\nLAST WEEKLY AUDIT COUNTS (may be stale)\n'
printf '%-12s %10s %10s %10s\n' "System" "Updates" "Security" "Reboot"
printf '%-12s %10s %10s %10s\n' "Proxmox" "${host_updates}" "${host_security}" "${host_reboot}"
printf '%-12s %10s %10s %10s\n' "CT 200" "${ct200_updates}" "${ct200_security}" "${ct200_reboot}"
printf '%-12s %10s %10s %10s\n' "CT 210" "${ct210_updates}" "${ct210_security}" "${ct210_reboot}"
printf '%-12s %10s %10s %10s\n' "CT 220" "${ct220_updates}" "${ct220_security}" "${ct220_reboot}"

printf '\nCONTROLLED DEBIAN SECURITY UPDATES\n%s\n' "${controlled_lines}"

printf '\nSCHEDULE\n'
printf '%-24s %s\n' "Next recovery backup:" "$(next_host_timer proxmox-bootstrap-backup.timer)"
printf '%-24s %s\n' "Next weekly audit:" "$(next_host_timer proxmox-bootstrap-update-audit.timer)"

printf '\nGUIDANCE\n'
if [[ "${audit_result}" != "SUCCESS" && "${audit_result}" != "WARNING" ]]; then
  printf 'The last weekly audit failed. Run: bash scripts/step20a-update-audit.sh\n'
elif grep -qE 'NOT CONFIGURED|UNAVAILABLE' <<<"${controlled_lines}"; then
  printf 'Controlled CT security updates need attention.\n'
  printf 'Run: bash scripts/step20g-unattended-upgrades-validation.sh\n'
elif grep -qE 'UPDATE FAILED|STATE ERROR' <<<"${controlled_lines}"; then
  printf 'A retained update snapshot needs inspection. Do not delete it blindly.\n'
elif grep -q 'CLEANUP DUE' <<<"${controlled_lines}"; then
  printf 'A successful update snapshot has completed its 24-hour observation period.\n'
  printf 'Run the cleanup command shown above for that CT.\n'
elif grep -q 'SNAPSHOT RETAINED' <<<"${controlled_lines}"; then
  printf 'A successful update snapshot is in its 24-hour observation period.\n'
  printf 'Leave it in place until the cleanup time shown above.\n'
else
  printf 'No automatic package installation is enabled.\n'
  printf 'Use step20-update-ct.sh for one snapshot-protected CT update.\n'
  printf 'Proxmox and application upgrades require separate reviewed procedures.\n'
fi
printf '\n'
