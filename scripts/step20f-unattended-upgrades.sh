#!/usr/bin/env bash
set -euo pipefail

STEP20_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${STEP20_SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

DRY_RUN=0
CONFIRM_INSTALL=0

usage() {
  cat <<EOF
Usage: $0 (--dry-run | --confirm-install)

Configures Debian unattended-upgrades for security repositories only in
CT 210, CT 220, and CT 200. Package installation remains manual through
step20-update-ct.sh. This never configures the Proxmox host.
EOF
}

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --confirm-install) CONFIRM_INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "Run as root"
(( DRY_RUN + CONFIRM_INSTALL == 1 )) || die "Choose exactly one of --dry-run or --confirm-install"
for cmd in apt-config awk pct; do
  command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"
done

CT_IDS=("${MQTT_CT_ID:-210}" "${HERMES_CT_ID:-220}" "${DOCKER_CT_ID:-200}")
for ct_id in "${CT_IDS[@]}"; do
  pct status "${ct_id}" | grep -q 'status: running' || die "CT ${ct_id} is not running"
  pct exec "${ct_id}" -- grep -qE \
    '^iface[[:space:]]+eth0[[:space:]]+inet[[:space:]]+dhcp' \
    /etc/network/interfaces \
    || die "CT ${ct_id}: eth0 is not managed by the expected ifupdown configuration"
  pct exec "${ct_id}" -- systemctl is-active --quiet networking.service \
    || die "CT ${ct_id}: networking.service is not active"
  if pct exec "${ct_id}" -- systemctl is-active --quiet systemd-networkd.service; then
    pct exec "${ct_id}" -- networkctl status eth0 --no-pager 2>/dev/null \
      | grep -q 'unmanaged' \
      || die "CT ${ct_id}: systemd-networkd unexpectedly manages eth0"
  fi
done

if (( DRY_RUN == 1 )); then
  log_info "UNATTENDED SECURITY UPDATE NON-MUTATING CHECK"
  apt-config -c "${PROJECT_ROOT}/config/20homelab-auto-upgrades" dump >/dev/null \
    || die "Periodic APT configuration is invalid"
  apt-config -c "${PROJECT_ROOT}/config/52homelab-unattended-upgrades" dump >/dev/null \
    || die "Unattended-upgrades policy is invalid"
  for ct_id in "${CT_IDS[@]}"; do
    log_info "Checking package simulation in CT ${ct_id}"
    simulation="$(pct exec "${ct_id}" -- apt-get -s install unattended-upgrades 2>&1)" \
      || die "CT ${ct_id}: unattended-upgrades package simulation failed"
    candidate="$(
      pct exec "${ct_id}" -- apt-cache policy unattended-upgrades 2>/dev/null \
        | awk '/Candidate:/ {print $2; exit}'
    )"
    [[ -n "${candidate}" && "${candidate}" != "(none)" ]] \
      || die "CT ${ct_id}: unattended-upgrades has no install candidate"
    changes="$(awk '/^(Inst|Remv|Conf) / {count++} END {print count+0}' <<<"${simulation}")"
    log_info "CT ${ct_id}: candidate=${candidate}, simulated package operations=${changes}"
    if pct exec "${ct_id}" -- systemctl is-enabled --quiet systemd-networkd.socket 2>/dev/null; then
      log_info "CT ${ct_id}: would disable the unused systemd-networkd socket to prevent APT wait-online timeouts"
    else
      log_info "CT ${ct_id}: unused systemd-networkd socket is already disabled"
    fi
  done
  log_info "Security package installation would remain manual through step20-update-ct.sh"
  log_info "The Proxmox host, Docker/Frigate images, Hermes releases, HAOS, and firmware would remain manual"
  log_info "Non-mutating check passed; no metadata, package, configuration, timer, or service was changed"
  exit 0
fi

for ct_id in "${CT_IDS[@]}"; do
  if pct exec "${ct_id}" -- systemctl is-active --quiet apt-daily-upgrade.service; then
    die "CT ${ct_id}: apt-daily-upgrade.service is running; wait for it to finish"
  fi
done
for ct_id in "${CT_IDS[@]}"; do
  log_info "Disabling independent automatic installation in CT ${ct_id}"
  pct exec "${ct_id}" -- systemctl disable --now apt-daily-upgrade.timer
done

for ct_id in "${CT_IDS[@]}"; do
  log_info "Configuring controlled Debian security updates in CT ${ct_id}"
  pct exec "${ct_id}" -- systemctl disable --now systemd-networkd.socket
  pct exec "${ct_id}" -- systemctl stop systemd-networkd.service
  pct exec "${ct_id}" -- timeout 5 /usr/lib/apt/apt-helper wait-online \
    || die "CT ${ct_id}: APT network readiness still fails after disabling unused systemd-networkd activation"
  if ! pct exec "${ct_id}" -- dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null \
      | grep -qx 'install ok installed'; then
    pct exec "${ct_id}" -- apt-get update >/dev/null
    pct exec "${ct_id}" -- env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y unattended-upgrades
  else
    log_info "CT ${ct_id}: unattended-upgrades is already installed"
  fi

  pct push "${ct_id}" "${PROJECT_ROOT}/config/20homelab-auto-upgrades" \
    /tmp/20homelab-auto-upgrades --perms 0600
  pct push "${ct_id}" "${PROJECT_ROOT}/config/52homelab-unattended-upgrades" \
    /tmp/52homelab-unattended-upgrades --perms 0600
  pct exec "${ct_id}" -- install -o root -g root -m 0644 \
    /tmp/20homelab-auto-upgrades /etc/apt/apt.conf.d/20homelab-auto-upgrades
  pct exec "${ct_id}" -- install -o root -g root -m 0644 \
    /tmp/52homelab-unattended-upgrades /etc/apt/apt.conf.d/52homelab-unattended-upgrades
  pct exec "${ct_id}" -- rm -f \
    /tmp/20homelab-auto-upgrades /tmp/52homelab-unattended-upgrades
  pct exec "${ct_id}" -- systemctl enable --now apt-daily.timer
done

bash "${STEP20_SCRIPT_DIR}/step20g-unattended-upgrades-validation.sh"
log_info "Controlled Debian security-update policy is configured"
