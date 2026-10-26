#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

CT_ID="${CLOUDFLARE_GATEWAY_CT_ID:-230}"
SNAPSHOT=""
CHANGING=0
usage() {
  echo 'Usage: step22c-cloudflared-upgrade.sh --dry-run | --apply'
  echo 'Preview uses cached APT metadata without changes. Apply refreshes APT and selects its stable candidate.'
}
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
case "$1" in
  --help) usage; exit 0 ;;
  --dry-run|--apply) MODE="$1" ;;
  *) die "Unknown argument: $1" ;;
esac
[[ ${EUID} -eq 0 ]] || die 'Run as root'
[[ "${CT_ID}" == 230 ]] || die 'This workflow is restricted to CT230'
for cmd in pct flock; do command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"; done
[[ "$(pct status "${CT_ID}")" == 'status: running' ]] || die 'CT230 must be running'
pct config "${CT_ID}" | grep -qx 'hostname: remote-gateway' || die 'Unexpected CT230 hostname'
pct exec "${CT_ID}" -- systemctl is-active --quiet cloudflared.service
installed="$(pct exec "${CT_ID}" -- dpkg-query -W '-f=${Version}' cloudflared)"
if [[ "${MODE}" == --apply ]]; then
  exec 9>/run/lock/proxmox-bootstrap-cloudflared.lock
  flock -n 9 || die 'Another cloudflared upgrade is running'
  exec 8>/run/lock/proxmox-bootstrap-backup.lock
  flock -n 8 || die 'A backup or restore operation is running'
  pct exec "${CT_ID}" -- apt-get update --error-on=any
else
  log_info 'Preview uses cached APT metadata; apply refreshes it and may select a newer release'
fi
policy="$(pct exec "${CT_ID}" -- env LC_ALL=C apt-cache policy cloudflared)"
TARGET="$(awk '$1 == "Candidate:" {print $2}' <<<"${policy}")"
[[ "${TARGET}" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || die "No stable numeric APT candidate: ${TARGET}"
# Require the selected version to be offered by the official Cloudflare repository.
available="$(pct exec "${CT_ID}" -- env LC_ALL=C apt-cache madison cloudflared)"
awk -F '|' -v target="${TARGET}" '
  {gsub(/^[ \t]+|[ \t]+$/, "", $2)}
  $2 == target && $3 ~ /^[ \t]*https:\/\/pkg\.cloudflare\.com\/cloudflared[ \t]/ {found=1}
  END {exit !found}
' <<<"${available}" || die 'Candidate is not available from the official Cloudflare APT repository'
log_info "CT230 cloudflared: ${installed}; target: ${TARGET}"
if pct exec "${CT_ID}" -- dpkg --compare-versions "${installed}" ge "${TARGET}"; then
  log_info 'Already at target or newer; no downgrade or restart needed'
  exit 0
fi
if [[ "${MODE}" == --dry-run ]]; then
  printf '%s\n' "${policy}"
  log_info "Would refresh APT and simulate cloudflared=${TARGET} before taking a rollback snapshot"
  log_info 'Would upgrade only cloudflared, restart it, and run gateway, Access and HA validations'
  log_info 'Failure after snapshot would restore CT230; successful snapshot is retained for manual cleanup'
  exit 0
fi

validate() {
  bash "${PROJECT_ROOT}/scripts/step22-cloudflare-gateway-validation.sh"
  bash "${PROJECT_ROOT}/scripts/step22a-cloudflare-access-validation.sh" --access-only
  bash "${PROJECT_ROOT}/scripts/step22b-cloudflare-homeassistant-validation.sh"
}
wait_service() {
  local attempt
  for ((attempt=0; attempt<30; attempt++)); do
    if pct exec "${CT_ID}" -- systemctl is-active --quiet cloudflared.service; then return 0; fi
    sleep 2
  done
  return 1
}
on_exit() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 && CHANGING == 1 )); then
    log_error "Upgrade failed; restoring CT230 snapshot ${SNAPSHOT}"
    if pct stop "${CT_ID}" && pct rollback "${CT_ID}" "${SNAPSHOT}" && pct start "${CT_ID}"; then
      if wait_service && validate; then
        log_warn 'Previous CT230 state restored and validated'
      else
        log_error 'Rollback completed but validation failed; inspect CT230 over Tailscale'
      fi
    else
      log_error "Automatic rollback failed; recover CT230 using snapshot ${SNAPSHOT} over Tailscale"
    fi
  fi
  exit "${rc}"
}
trap on_exit EXIT

validate
pct exec "${CT_ID}" -- apt-get --simulate --no-remove install --only-upgrade "cloudflared=${TARGET}"
SNAPSHOT="cf-upgrade-$(date -u +%Y%m%dT%H%M%SZ)-$$"
# The stateless connector needs disk state only, with no saved process memory.
# Snapshot failure aborts before package installation; no snapshot is deleted automatically.
pct snapshot "${CT_ID}" "${SNAPSHOT}" --description "Before cloudflared ${installed} to ${TARGET}"
log_info "Rollback snapshot retained: ${SNAPSHOT}"
CHANGING=1
pct exec "${CT_ID}" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove --only-upgrade "cloudflared=${TARGET}"
pct exec "${CT_ID}" -- systemctl restart cloudflared.service
wait_service
actual="$(pct exec "${CT_ID}" -- dpkg-query -W '-f=${Version}' cloudflared)"
[[ "${actual}" == "${TARGET}" ]] || die "Unexpected installed version: ${actual}"
pct exec "${CT_ID}" -- cloudflared --version
# Allow the connector time to register with Cloudflare before API checks.
sleep 10
validate
CHANGING=0
log_info "Upgrade validated. Retain snapshot ${SNAPSHOT} through observation and the owner mobile-data OTP test."
log_info "After acceptance, remove explicitly: pct delsnapshot ${CT_ID} ${SNAPSHOT}"
