#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

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

effective_policy_matches() {
  local ct_id="$1" policy origin_count allowed_count
  policy="$(pct exec "${ct_id}" -- apt-config dump 2>/dev/null)" || return 1
  origin_count="$(
    grep -c '^Unattended-Upgrade::Origins-Pattern:: "' <<<"${policy}" || true
  )"
  allowed_count="$(
    grep -c '^Unattended-Upgrade::Allowed-Origins:: "' <<<"${policy}" || true
  )"
  grep -Fq 'APT::Periodic::Unattended-Upgrade "0";' <<<"${policy}" \
    && grep -Fq 'origin=Debian,codename=${distro_codename},label=Debian-Security' <<<"${policy}" \
    && grep -Fq 'origin=Debian,codename=${distro_codename}-security,label=Debian-Security' <<<"${policy}" \
    && grep -Fq 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"${policy}" \
    && grep -Fq 'Unattended-Upgrade::MinimalSteps "true";' <<<"${policy}" \
    && [[ "${origin_count}" == "2" ]] \
    && [[ "${allowed_count}" == "0" ]]
}

networkd_does_not_manage_eth0() {
  local ct_id="$1"
  if ! pct exec "${ct_id}" -- systemctl is-active --quiet systemd-networkd.service; then
    return 0
  fi
  pct exec "${ct_id}" -- networkctl status eth0 --no-pager 2>/dev/null \
    | grep -q unmanaged
}

usage() {
  cat <<EOF
Usage: $0 [all|ct200|ct210|ct220]
EOF
}

[[ "${EUID}" -eq 0 ]] || die "Run as root"
TARGET="${1:-all}"
TARGET="${TARGET,,}"
case "${TARGET}" in
  all) CT_IDS=("${MQTT_CT_ID:-210}" "${HERMES_CT_ID:-220}" "${DOCKER_CT_ID:-200}") ;;
  ct200) CT_IDS=("${DOCKER_CT_ID:-200}") ;;
  ct210) CT_IDS=("${MQTT_CT_ID:-210}") ;;
  ct220) CT_IDS=("${HERMES_CT_ID:-220}") ;;
  *) usage; die "Unknown validation target: ${TARGET}" ;;
esac

for ct_id in "${CT_IDS[@]}"; do
  log_info "Validating controlled security updates in CT ${ct_id}"
  check "CT ${ct_id} is running" bash -c "pct status '${ct_id}' | grep -q 'status: running'"
  check "CT ${ct_id} unattended-upgrades installed" \
    bash -c "pct exec '${ct_id}' -- dpkg-query -W -f='\${Status}\\n' unattended-upgrades | grep -qx 'install ok installed'"
  check "CT ${ct_id} periodic config matches" \
    remote_matches "${ct_id}" "${PROJECT_ROOT}/config/20homelab-auto-upgrades" \
      /etc/apt/apt.conf.d/20homelab-auto-upgrades
  check "CT ${ct_id} security policy matches" \
    remote_matches "${ct_id}" "${PROJECT_ROOT}/config/52homelab-unattended-upgrades" \
      /etc/apt/apt.conf.d/52homelab-unattended-upgrades
  check "CT ${ct_id} effective APT security policy is loaded" \
    effective_policy_matches "${ct_id}"
  check "CT ${ct_id} ifupdown networking is active" \
    pct exec "${ct_id}" -- systemctl is-active --quiet networking.service
  check "CT ${ct_id} eth0 is not managed by systemd-networkd" \
    networkd_does_not_manage_eth0 "${ct_id}"
  check "CT ${ct_id} unused systemd-networkd socket is disabled" \
    bash -c "! pct exec '${ct_id}' -- systemctl is-enabled --quiet systemd-networkd.socket"
  check "CT ${ct_id} unused systemd-networkd service is inactive" \
    bash -c "! pct exec '${ct_id}' -- systemctl is-active --quiet systemd-networkd.service"
  check "CT ${ct_id} APT network readiness succeeds" \
    pct exec "${ct_id}" -- timeout 5 /usr/lib/apt/apt-helper wait-online
  check "CT ${ct_id} apt-daily timer enabled" \
    pct exec "${ct_id}" -- systemctl is-enabled --quiet apt-daily.timer
  check "CT ${ct_id} automatic install timer disabled" \
    bash -c "! pct exec '${ct_id}' -- systemctl is-enabled --quiet apt-daily-upgrade.timer"
  check "CT ${ct_id} automatic install timer inactive" \
    bash -c "! pct exec '${ct_id}' -- systemctl is-active --quiet apt-daily-upgrade.timer"
done

(( errors == 0 )) || die "Controlled security update validation failed with ${errors} error(s)"
log_info "Controlled security update validation completed successfully"
