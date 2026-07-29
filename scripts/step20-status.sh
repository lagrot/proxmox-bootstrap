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

auto_security_details() {
  local ct_id="$1" local_hash remote_hash local_periodic_hash remote_periodic_hash
  local effective_policy origin_count allowed_count service_result last_run next_run
  local config_epoch last_run_epoch
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
    || ! pct exec "${ct_id}" -- systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null \
    || ! pct exec "${ct_id}" -- systemctl is-active --quiet apt-daily-upgrade.timer 2>/dev/null \
    || [[ "${remote_hash}" != "${local_hash}" ]] \
    || [[ "${remote_periodic_hash}" != "${local_periodic_hash}" ]] \
    || [[ "${origin_count}" != "2" || "${allowed_count}" != "0" ]] \
    || ! grep -Fq 'APT::Periodic::Unattended-Upgrade "1";' <<<"${effective_policy}"; then
    printf 'CT %s: NOT CONFIGURED\n' "${ct_id}"
    return
  fi

  service_result="$(
    pct exec "${ct_id}" -- systemctl show apt-daily-upgrade.service \
      -p Result --value 2>/dev/null || true
  )"
  last_run="$(
    pct exec "${ct_id}" -- systemctl show apt-daily-upgrade.service \
      -p InactiveExitTimestamp --value 2>/dev/null || true
  )"
  next_run="$(
    pct exec "${ct_id}" -- systemctl show apt-daily-upgrade.timer \
      -p NextElapseUSecRealtime --value 2>/dev/null || true
  )"
  config_epoch="$(
    pct exec "${ct_id}" -- stat -c %Y \
      /etc/apt/apt.conf.d/52homelab-unattended-upgrades 2>/dev/null || true
  )"

  last_run_epoch="$(date -d "${last_run}" +%s 2>/dev/null || true)"
  if [[ -z "${last_run_epoch}" || -z "${config_epoch}" || "${last_run_epoch}" -lt "${config_epoch}" ]]; then
    service_result="pending first run"
    last_run="none under current policy"
  elif [[ -z "${service_result}" ]]; then
    service_result="unknown"
  else
    last_run="$(date '+%Y-%m-%d %H:%M %Z' -d "${last_run}" 2>/dev/null || printf '%s' "${last_run}")"
  fi
  if [[ -n "${next_run}" ]]; then
    next_run="$(date '+%Y-%m-%d %H:%M %Z' -d "${next_run}" 2>/dev/null || printf '%s' "${next_run}")"
  else
    next_run="not scheduled"
  fi
  printf 'CT %s: ENABLED | last=%s at %s | next=%s\n' \
    "${ct_id}" "${service_result}" "${last_run}" "${next_run}"
}

ct200_reboot="$(reboot_state "${DOCKER_CT_ID:-200}")"
ct210_reboot="$(reboot_state "${MQTT_CT_ID:-210}")"
ct220_reboot="$(reboot_state "${HERMES_CT_ID:-220}")"

auto_lines="$(
  auto_security_details "${DOCKER_CT_ID:-200}"
  auto_security_details "${MQTT_CT_ID:-210}"
  auto_security_details "${HERMES_CT_ID:-220}"
)"

printf '\nUPDATE OPERATIONS STATUS\n'
printf '%s\n' '========================'
printf '%-24s %s\n' "Last weekly audit:" "${audit_completed_display}"
printf '%-24s %s\n' "Audit result:" "${audit_result}"
printf '%-24s %s\n' "Recovery backup:" "${backup_state} (not an automatic-update gate)"
printf '%-24s %s\n' "Last recovery backup:" "${backup_time}"
printf '%-24s %s\n' "Backup path:" "${backup_path}"

printf '\nLAST WEEKLY AUDIT COUNTS (may be stale)\n'
printf '%-12s %10s %10s %10s\n' "System" "Updates" "Security" "Reboot"
printf '%-12s %10s %10s %10s\n' "Proxmox" "${host_updates}" "${host_security}" "${host_reboot}"
printf '%-12s %10s %10s %10s\n' "CT 200" "${ct200_updates}" "${ct200_security}" "${ct200_reboot}"
printf '%-12s %10s %10s %10s\n' "CT 210" "${ct210_updates}" "${ct210_security}" "${ct210_reboot}"
printf '%-12s %10s %10s %10s\n' "CT 220" "${ct220_updates}" "${ct220_security}" "${ct220_reboot}"

printf '\nAUTOMATIC DEBIAN SECURITY UPDATES\n%s\n' "${auto_lines}"

printf '\nSCHEDULE\n'
printf '%-24s %s\n' "Next recovery backup:" "$(next_host_timer proxmox-bootstrap-backup.timer)"
printf '%-24s %s\n' "Next weekly audit:" "$(next_host_timer proxmox-bootstrap-update-audit.timer)"

printf '\nGUIDANCE\n'
if [[ "${audit_result}" != "SUCCESS" && "${audit_result}" != "WARNING" ]]; then
  printf 'The last weekly audit failed. Run: bash scripts/step20a-update-audit.sh\n'
elif grep -qE 'NOT CONFIGURED|UNAVAILABLE' <<<"${auto_lines}"; then
  printf 'Automatic CT security updates need attention.\n'
  printf 'Run: bash scripts/step20g-unattended-upgrades-validation.sh\n'
elif grep -qE 'last=(failed|exit-code|timeout|resources|signal|core-dump|watchdog|start-limit-hit)' \
    <<<"${auto_lines}"; then
  printf 'An automatic update failed. Inspect the unattended-upgrades logs.\n'
elif grep -q 'last=pending first run' <<<"${auto_lines}"; then
  printf 'Configuration is healthy; verify the first run after its scheduled time.\n'
else
  printf 'No routine action is required. CT security updates are automatic.\n'
  printf 'Proxmox and application upgrades require separate reviewed procedures.\n'
fi
printf '\n'
