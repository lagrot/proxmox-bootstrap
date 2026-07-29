#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

TARGET="${1:-}"
TARGET="${TARGET,,}"
UPDATE_MAX_BACKUP_AGE_DAYS="${UPDATE_MAX_BACKUP_AGE_DAYS:-8}"

usage() {
  cat <<EOF
Usage: $0 TARGET

Command targets:
  proxmox, ct200, docker, ct210, mqtt, ct220

Special guidance:
  homeassistant, frigate, zigbee

Unavailable:
  hermes (no tested application-upgrade procedure)

This script validates the maintenance gates and prints commands only. It never
installs packages, changes images, updates firmware, or reboots anything.
EOF
}

[[ "${EUID}" -eq 0 ]] || die "Run as root"
[[ -n "${TARGET}" ]] || { usage; exit 1; }
if [[ "${TARGET}" == "hermes" ]]; then
  cat <<'EOF'
BLOCKED: No tested Hermes application-upgrade procedure exists.
Do not upgrade Hermes with Step 20.
CT 220 Debian security updates are handled automatically.
EOF
  exit 2
fi
[[ -f "${UPDATE_STATUS_FILE}" ]] || die "Run Step 20A before planning maintenance"
grep -qE '"status": "(success|warning)"' "${UPDATE_STATUS_FILE}" \
  || die "Latest update audit did not complete successfully"
[[ -f "${BACKUP_STATUS_FILE}" && -f "${BACKUP_LAST_SUCCESS_FILE}" ]] \
  || die "Backup status is unavailable"
grep -q '"status": "success"' "${BACKUP_STATUS_FILE}" || die "Latest backup operation was not successful"
latest_backup="$(<"${BACKUP_LAST_SUCCESS_FILE}")"
[[ -f "${latest_backup}/.validated" ]] || die "Latest backup is not validated"
backup_age="$(( $(date +%s) - $(stat -c %Y "${latest_backup}/.validated") ))"
(( backup_age <= UPDATE_MAX_BACKUP_AGE_DAYS * 86400 )) \
  || die "Latest validated backup is older than ${UPDATE_MAX_BACKUP_AGE_DAYS} days"

log_info "Maintenance gates passed for target: ${TARGET}"
log_info "Validated backup: ${latest_backup}"
log_warn "Run one target at a time and review the package transaction before confirming it"

case "${TARGET}" in
  proxmox)
    cat <<'EOF'
apt-get update
apt-get dist-upgrade
# Review /var/run/reboot-required and the installed/running PVE kernel.
bash scripts/step20c-post-update-validation.sh proxmox
EOF
    ;;
  ct200)
    cat <<'EOF'
pct enter 200
apt-get update
apt-get dist-upgrade
exit
bash scripts/step20c-post-update-validation.sh ct200
EOF
    ;;
  docker)
    cat <<'EOF'
pct enter 200
apt-get update
apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
exit
bash scripts/step20c-post-update-validation.sh docker
EOF
    ;;
  ct210)
    cat <<'EOF'
pct enter 210
apt-get update
apt-get dist-upgrade
exit
bash scripts/step20c-post-update-validation.sh ct210
EOF
    ;;
  mqtt)
    cat <<'EOF'
pct enter 210
apt-get update
apt-get install --only-upgrade mosquitto mosquitto-clients
exit
bash scripts/step20c-post-update-validation.sh mqtt
EOF
    ;;
  ct220)
    cat <<'EOF'
pct enter 220
apt-get update
apt-get dist-upgrade
exit
bash scripts/step20c-post-update-validation.sh ct220
EOF
    ;;
  homeassistant)
    cat <<'EOF'
# Preferred: Home Assistant UI -> Settings -> System -> Updates.
# Update Core, Supervisor, OS, integrations, and apps separately.
# Ensure each offered update creates a backup, then run:
bash scripts/step20c-post-update-validation.sh homeassistant
EOF
    ;;
  frigate)
    cat <<'EOF'
# Replace X.Y.Z only after selecting a stable release and reviewing its notes.
bash scripts/step18a-frigate-upgrade-preflight.sh --target X.Y.Z --release-notes-reviewed
bash scripts/step18b-frigate-upgrade.sh --target X.Y.Z --release-notes-reviewed --dry-run
# A real upgrade additionally requires --confirm-upgrade.
EOF
    ;;
  zigbee)
    cat <<'EOF'
# Do not update coordinator firmware routinely.
# Back up the Zigbee network, verify an applicable stable firmware and its
# release notes, stop ZHA before flashing, then run:
bash scripts/step20c-post-update-validation.sh zigbee
EOF
    ;;
  *)
    usage
    die "Unknown update target: ${TARGET}"
    ;;
esac
