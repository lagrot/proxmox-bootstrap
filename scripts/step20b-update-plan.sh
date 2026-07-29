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
CONTROLLED UPDATE TARGET: CT ${DOCKER_CT_ID}
Only installed packages offered by Debian Security are eligible.
Docker Engine/Compose from download.docker.com and the Frigate image are not
updated by this target.
Step 12 backs up service configuration, not the complete CT root filesystem.

Preview the exact security-only transaction:
  bash scripts/step20-update-ct.sh ct200 --dry-run

After review, follow UPDATE-QUICK-GUIDE.txt for confirm and cleanup.
A generic full upgrade is not provided.
EOF
    ;;
  ct210)
    cat <<EOF
CONTROLLED UPDATE TARGET: CT ${MQTT_CT_ID}
Only installed packages offered by Debian Security are eligible. This may
include Mosquitto when Debian Security publishes a fix because Mosquitto is a
native Debian package.
Step 12 backs up Mosquitto configuration, not the complete CT root filesystem.

Preview the exact security-only transaction:
  bash scripts/step20-update-ct.sh ct210 --dry-run

After review, follow UPDATE-QUICK-GUIDE.txt for confirm and cleanup.
A generic full upgrade is not provided.
EOF
    ;;
  ct220)
    cat <<EOF
CONTROLLED UPDATE TARGET: CT ${HERMES_CT_ID}
Only installed packages offered by Debian Security are eligible.
The Hermes application is not a Debian package and is not updated by this
target.
Step 12 backs up Hermes application data, not the complete CT root filesystem.

Preview the exact security-only transaction:
  bash scripts/step20-update-ct.sh ct220 --dry-run

After review, follow UPDATE-QUICK-GUIDE.txt for confirm and cleanup.
A generic full upgrade is not provided.
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
