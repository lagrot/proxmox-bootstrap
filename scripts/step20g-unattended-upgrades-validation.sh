#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"

errors=0
check() {
  local label="$1"
  shift
  if "$@"; then
    log_info "PASS: ${label}"
  else
    log_error "FAIL: ${label}"
    ((errors+=1))
  fi
}

remote_matches() {
  local ct_id="$1" local_file="$2" remote_file="$3" local_hash remote_hash
  local_hash="$(sha256sum "${local_file}" | awk '{print $1}')"
  remote_hash="$(pct exec "${ct_id}" -- sha256sum "${remote_file}" 2>/dev/null | awk '{print $1}')"
  [[ "${remote_hash}" == "${local_hash}" ]]
}

[[ "${EUID}" -eq 0 ]] || die "Run as root"
CT_IDS=("${MQTT_CT_ID:-210}" "${HERMES_CT_ID:-220}" "${DOCKER_CT_ID:-200}")

for ct_id in "${CT_IDS[@]}"; do
  log_info "Validating unattended security updates in CT ${ct_id}"
  check "CT ${ct_id} is running" bash -c "pct status '${ct_id}' | grep -q 'status: running'"
  check "CT ${ct_id} unattended-upgrades installed" \
    bash -c "pct exec '${ct_id}' -- dpkg-query -W -f='\${Status}\\n' unattended-upgrades | grep -qx 'install ok installed'"
  check "CT ${ct_id} periodic config matches" \
    remote_matches "${ct_id}" "${PROJECT_ROOT}/config/20homelab-auto-upgrades" \
      /etc/apt/apt.conf.d/20homelab-auto-upgrades
  check "CT ${ct_id} security policy matches" \
    remote_matches "${ct_id}" "${PROJECT_ROOT}/config/52homelab-unattended-upgrades" \
      /etc/apt/apt.conf.d/52homelab-unattended-upgrades
  check "CT ${ct_id} apt-daily timer enabled" \
    pct exec "${ct_id}" -- systemctl is-enabled --quiet apt-daily.timer
  check "CT ${ct_id} apt-daily-upgrade timer enabled" \
    pct exec "${ct_id}" -- systemctl is-enabled --quiet apt-daily-upgrade.timer
  check "CT ${ct_id} apt-daily-upgrade timer active" \
    pct exec "${ct_id}" -- systemctl is-active --quiet apt-daily-upgrade.timer
done

(( errors == 0 )) || die "Unattended security update validation failed with ${errors} error(s)"
log_info "Unattended security update validation completed successfully"
