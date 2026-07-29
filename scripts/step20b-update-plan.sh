#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

TARGET="${1:-}"
TARGET="${TARGET,,}"

usage() {
  cat <<EOF
Usage: $0 TARGET

Review only:
  proxmox, ct200, ct210, ct220

Dedicated procedure:
  homeassistant, frigate

Unavailable:
  docker, mqtt, hermes, zigbee

This command never installs packages, changes images, updates firmware,
creates snapshots, or reboots anything.
EOF
}

[[ "${EUID}" -eq 0 ]] || die "Run as root"
[[ -n "${TARGET}" ]] || { usage; exit 1; }

case "${TARGET}" in
  proxmox)
    cat <<'EOF'
REVIEW ONLY: Step 12 does not back up the Proxmox host.
No generic Proxmox apply command is provided.

Inspect the cached package transaction:
  apt-get -s dist-upgrade

Before a real host upgrade, define host recovery, console access, the exact
package transaction, reboot handling, and post-update validation.
EOF
    ;;
  ct200)
    cat <<EOF
REVIEW ONLY: CT ${DOCKER_CT_ID} Debian security updates are automatic.
Step 12 backs up service configuration, not the complete CT root filesystem.
No generic full-upgrade command is provided.

Inspect the cached package transaction:
  pct exec ${DOCKER_CT_ID} -- apt-get -s dist-upgrade
EOF
    ;;
  ct210)
    cat <<EOF
REVIEW ONLY: CT ${MQTT_CT_ID} Debian security updates are automatic.
Step 12 backs up Mosquitto configuration, not the complete CT root filesystem.
No generic full-upgrade command is provided.

Inspect the cached package transaction:
  pct exec ${MQTT_CT_ID} -- apt-get -s dist-upgrade
EOF
    ;;
  ct220)
    cat <<EOF
REVIEW ONLY: CT ${HERMES_CT_ID} Debian security updates are automatic.
Step 12 backs up Hermes application data, not the complete CT root filesystem.
No generic full-upgrade command is provided.

Inspect the cached package transaction:
  pct exec ${HERMES_CT_ID} -- apt-get -s dist-upgrade
EOF
    ;;
  homeassistant)
    cat <<'EOF'
DEDICATED PROCEDURE: Use Home Assistant UI -> Settings -> System -> Updates.
Review each offered update separately and create its Home Assistant backup.
Afterward, validate with:
  bash scripts/step20c-post-update-validation.sh homeassistant
EOF
    ;;
  frigate)
    cat <<'EOF'
DEDICATED PROCEDURE: Follow docs/step18-frigate-upgrade.md.
Start with a selected stable version and the Step 18 preflight and dry run.
Do not use a generic Docker image update.
EOF
    ;;
  docker|mqtt|hermes|zigbee)
    printf 'BLOCKED: No tested generic %s update procedure exists.\n' "${TARGET}"
    printf 'Do not apply this update through Step 20.\n'
    exit 2
    ;;
  *)
    usage
    die "Unknown update target: ${TARGET}"
    ;;
esac
