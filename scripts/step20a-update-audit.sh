#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

export LOG_FILE="${UPDATE_LOG_FILE:-/var/log/proxmox-bootstrap/update-audit.log}"
source "${PROJECT_ROOT}/lib/common.sh"

UPDATE_STATUS_FILE="${UPDATE_STATUS_FILE:-/var/lib/proxmox-bootstrap/update-audit-status.json}"
UPDATE_MAX_BACKUP_AGE_DAYS="${UPDATE_MAX_BACKUP_AGE_DAYS:-8}"
UPDATE_AUDIT_REFRESH="${UPDATE_AUDIT_REFRESH:-1}"
LOCK_FILE="/run/lock/proxmox-bootstrap-update-audit.lock"
START_AT="$(date --iso-8601=seconds)"
AUDIT_ERRORS=0
AUDIT_WARNINGS=0
HOST_UPDATES=0
HOST_SECURITY=0
CT200_UPDATES=0
CT200_SECURITY=0
CT210_UPDATES=0
CT210_SECURITY=0
CT220_UPDATES=0
CT220_SECURITY=0
BACKUP_READY=false
HOST_REBOOT=false
STATUS_WRITTEN=0

record_error() { log_error "$1"; ((AUDIT_ERRORS+=1)); }
record_warn() { log_warn "$1"; ((AUDIT_WARNINGS+=1)); }

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/ }"
  printf '%s' "${value}"
}

package_audit() {
  local label="$1" scope="$2"
  local simulation security_simulation security_list
  local updates security packages security_packages
  log_info "Auditing package state: ${label}"
  if [[ "${UPDATE_AUDIT_REFRESH}" == "1" ]]; then
    log_info "Refreshing package metadata: ${label}"
    if [[ "${scope}" == "host" ]]; then
      apt-get update >/dev/null || { record_error "${label}: apt metadata refresh failed"; return; }
    else
      pct exec "${scope}" -- apt-get update >/dev/null \
        || { record_error "${label}: apt metadata refresh failed"; return; }
    fi
  fi

  if [[ "${scope}" == "host" ]]; then
    simulation="$(apt-get -s dist-upgrade 2>&1)" \
      || { record_error "${label}: package simulation failed"; return; }
  else
    simulation="$(pct exec "${scope}" -- apt-get -s dist-upgrade 2>&1)" \
      || { record_error "${label}: package simulation failed"; return; }
  fi
  updates="$(awk '/^Inst / {count++} END {print count+0}' <<<"${simulation}")"
  packages="$(awk '/^Inst / {print $2}' <<<"${simulation}" | paste -sd, -)"
  if [[ "${scope}" == "host" ]]; then
    security="$(
      awk 'BEGIN{IGNORECASE=1} /^Inst / && /security/ {count++} END {print count+0}' \
        <<<"${simulation}"
    )"
    security_packages="$(
      awk 'BEGIN{IGNORECASE=1} /^Inst / && /security/ {print $2}' \
        <<<"${simulation}" | paste -sd, -
    )"
  else
    security_simulation="$(
      pct exec "${scope}" -- unattended-upgrade --dry-run --verbose 2>&1
    )" || {
      record_error "${label}: Debian Security simulation failed"
      return
    }
    security_list="$(
      sed -n 's/^Packages that will be upgraded: //p' \
        <<<"${security_simulation}" \
        | tail -1 | tr ' ' '\n' | sed '/^$/d' | sort -u
    )"
    security="$(awk 'NF {count++} END {print count+0}' <<<"${security_list}")"
    security_packages="$(paste -sd, - <<<"${security_list}")"
  fi
  log_info "${label}: pending=${updates} debian_security=${security}"
  [[ -z "${packages}" ]] || log_info "${label}: packages=${packages}"
  [[ -z "${security_packages}" ]] || log_warn "${label}: security_packages=${security_packages}"
  printf -v "${3}" '%d' "${updates}"
  printf -v "${4}" '%d' "${security}"
}

guest_ha_info() {
  local component="$1"
  qm guest exec "${HA_VM_ID}" -- ha "${component}" info 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data","").strip())'
}

write_status() {
  local status="$1" message="$2" temp
  temp="${UPDATE_STATUS_FILE}.tmp"
  printf '{\n  "schema_version": 1,\n  "started_at": "%s",\n  "completed_at": "%s",\n  "status": "%s",\n  "message": "%s",\n  "package_updates": {\n    "proxmox_host": {"total": %d, "debian_security": %d},\n    "ct200": {"total": %d, "debian_security": %d},\n    "ct210": {"total": %d, "debian_security": %d},\n    "ct220": {"total": %d, "debian_security": %d}\n  },\n  "backup_ready": %s,\n  "host_reboot_required": %s,\n  "warnings": %d,\n  "errors": %d\n}\n' \
    "${START_AT}" "$(date --iso-8601=seconds)" \
    "$(json_escape "${status}")" "$(json_escape "${message}")" \
    "${HOST_UPDATES}" "${HOST_SECURITY}" "${CT200_UPDATES}" "${CT200_SECURITY}" \
    "${CT210_UPDATES}" "${CT210_SECURITY}" "${CT220_UPDATES}" "${CT220_SECURITY}" \
    "${BACKUP_READY}" "${HOST_REBOOT}" "${AUDIT_WARNINGS}" "${AUDIT_ERRORS}" >"${temp}"
  chmod 0600 "${temp}"
  mv -f "${temp}" "${UPDATE_STATUS_FILE}"
  STATUS_WRITTEN=1
}

unexpected_failure() {
  local rc="$?"
  trap - ERR
  if (( STATUS_WRITTEN == 0 )); then
    AUDIT_ERRORS=$((AUDIT_ERRORS + 1))
    write_status failed "Update audit stopped unexpectedly"
  fi
  exit "${rc}"
}

log_probe() {
  local label="$1" value
  shift
  if value="$("$@" 2>&1)"; then
    log_info "${label}: ${value%%$'\n'*}"
  else
    record_warn "${label}: unavailable"
  fi
}

log_info "======================================"
log_info "STEP 20A - UPDATE OPERATIONS AUDIT"
log_info "======================================"

[[ "${EUID}" -eq 0 ]] || die "Run as root"
[[ "${UPDATE_MAX_BACKUP_AGE_DAYS}" =~ ^[1-9][0-9]*$ ]] || die "UPDATE_MAX_BACKUP_AGE_DAYS must be positive"
for cmd in apt-get awk date flock paste pct pveversion python3 qm sed sort tail tr; do
  command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"
done
mkdir -p "$(dirname "${LOG_FILE}")" "$(dirname "${UPDATE_STATUS_FILE}")"
touch "${LOG_FILE}"
chown root:adm "${LOG_FILE}" 2>/dev/null || chown root:root "${LOG_FILE}"
chmod 0640 "${LOG_FILE}"
chmod 0700 "$(dirname "${UPDATE_STATUS_FILE}")"
exec 9>"${LOCK_FILE}"
flock -n 9 || die "Another update audit is running"
trap unexpected_failure ERR

log_info "Checking latest validated backup..."
if [[ -f "${BACKUP_STATUS_FILE}" && -f "${BACKUP_LAST_SUCCESS_FILE}" ]] \
  && grep -q '"status": "success"' "${BACKUP_STATUS_FILE}"; then
  latest_backup="$(<"${BACKUP_LAST_SUCCESS_FILE}")"
  if [[ -d "${latest_backup}" && -f "${latest_backup}/.validated" ]]; then
    backup_age_seconds="$(( $(date +%s) - $(stat -c %Y "${latest_backup}/.validated") ))"
    if (( backup_age_seconds <= UPDATE_MAX_BACKUP_AGE_DAYS * 86400 )); then
      BACKUP_READY=true
      log_info "Latest validated backup is within ${UPDATE_MAX_BACKUP_AGE_DAYS} days: ${latest_backup}"
    else
      record_warn "Latest validated backup is older than ${UPDATE_MAX_BACKUP_AGE_DAYS} days"
    fi
  else
    record_error "Backup last-success pointer is not a validated backup"
  fi
else
  record_error "Successful backup status is unavailable"
fi

log_info "Installed versions:"
log_probe "Proxmox" pveversion
log_probe "Kernel" uname -r
log_probe "Docker" pct exec "${DOCKER_CT_ID}" -- docker version --format '{{.Server.Version}}'
log_probe "Docker Compose" pct exec "${DOCKER_CT_ID}" -- docker compose version --short
log_probe "Frigate image" pct exec "${DOCKER_CT_ID}" -- docker inspect --format '{{.Config.Image}}' frigate
log_probe "Mosquitto" pct exec "${MQTT_CT_ID}" -- \
  dpkg-query -W -f='${Version}' mosquitto
log_probe "Hermes" pct exec "${HERMES_CT_ID}" -- su - hermes -c 'hermes --version'

if qm agent "${HA_VM_ID}" ping >/dev/null 2>&1; then
  if core_info="$(guest_ha_info core)" \
    && os_info="$(guest_ha_info os)" \
    && supervisor_info="$(guest_ha_info supervisor)"; then
    log_info "Home Assistant Core: $(awk -F': ' '$1=="version"{print $2}' <<<"${core_info}") (latest $(awk -F': ' '$1=="version_latest"{print $2}' <<<"${core_info}"))"
    log_info "Home Assistant OS: $(awk -F': ' '$1=="version"{print $2}' <<<"${os_info}") (latest $(awk -F': ' '$1=="version_latest"{print $2}' <<<"${os_info}"))"
    log_info "Home Assistant Supervisor: $(awk -F': ' '$1=="version"{print $2}' <<<"${supervisor_info}") (latest $(awk -F': ' '$1=="version_latest"{print $2}' <<<"${supervisor_info}"))"
  else
    record_warn "Home Assistant version information was not available"
  fi
  zigbee_info="$(qm guest exec "${HA_VM_ID}" -- bash -c 'udevadm info --query=property --name=/dev/ttyUSB0 2>/dev/null | grep -E "^(ID_MODEL|ID_SERIAL|ID_REVISION)="' 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("out-data","").strip())' || true)"
  if [[ -n "${zigbee_info}" ]]; then
    log_info "Zigbee coordinator: $(tr '\n' ' ' <<<"${zigbee_info}")"
    log_info "Zigbee radio firmware: not exposed by the standard HAOS hardware API"
  else
    record_warn "Zigbee coordinator identity was not available"
  fi
else
  record_warn "Home Assistant guest agent is unavailable"
fi

[[ -e /var/run/reboot-required ]] && HOST_REBOOT=true
log_info "Host reboot marker: ${HOST_REBOOT}"
for ct_id in "${DOCKER_CT_ID}" "${MQTT_CT_ID}" "${HERMES_CT_ID}"; do
  if ! pct status "${ct_id}" 2>/dev/null | grep -q 'status: running'; then
    record_warn "CT ${ct_id} is not running; reboot marker is unavailable"
  elif pct exec "${ct_id}" -- test -e /var/run/reboot-required; then
    record_warn "CT ${ct_id} has a reboot-required marker"
  else
    log_info "CT ${ct_id} reboot marker: false"
  fi
done

package_audit "Proxmox host" host HOST_UPDATES HOST_SECURITY
package_audit "CT ${DOCKER_CT_ID}" "${DOCKER_CT_ID}" CT200_UPDATES CT200_SECURITY
package_audit "CT ${MQTT_CT_ID}" "${MQTT_CT_ID}" CT210_UPDATES CT210_SECURITY
package_audit "CT ${HERMES_CT_ID}" "${HERMES_CT_ID}" CT220_UPDATES CT220_SECURITY

if (( AUDIT_ERRORS > 0 )); then
  write_status failed "Update audit failed"
  trap - ERR
  die "Update audit failed with ${AUDIT_ERRORS} error(s)"
fi
if (( AUDIT_WARNINGS > 0 )); then
  write_status warning "Update audit completed with warnings"
  log_warn "Update audit completed with ${AUDIT_WARNINGS} warning(s)"
else
  write_status success "Update audit completed successfully"
  log_info "Update audit completed successfully"
fi
trap - ERR
