#!/usr/bin/env bash
set -euo pipefail
umask 0077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

CT_ID="${DOCKER_CT_ID:-200}"
APP_DIR="${FRIGATE_APP_DIR:-/opt/frigate}"
CONFIG_DIR="${FRIGATE_CONFIG_DIR:-${APP_DIR}/config}"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
TARGET_VERSION=""
RELEASE_NOTES_REVIEWED=0
SKIP_PULL=0
VALIDATION_DIR="/tmp/frigate-upgrade-preflight"

usage() {
  cat <<EOF
Usage: $0 --target X.Y.Z --release-notes-reviewed [--skip-pull]

Read-only Frigate stable-upgrade preflight. It never edits Compose/config,
stops Frigate, or recreates the container. --skip-pull requires the exact
target image to exist locally.
EOF
}

while (($#)); do
  case "$1" in
    --target) [[ $# -ge 2 ]] || die "--target requires a version"; TARGET_VERSION="$2"; shift 2 ;;
    --release-notes-reviewed) RELEASE_NOTES_REVIEWED=1; shift ;;
    --skip-pull) SKIP_PULL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in pct grep awk; do command -v "$cmd" >/dev/null || die "Missing command: $cmd"; done
[[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "Target must be an exact stable version such as 0.18.0; moving tags and prereleases are rejected"
(( RELEASE_NOTES_REVIEWED == 1 )) || die "Pass --release-notes-reviewed after reviewing the target release notes"
pct status "$CT_ID" | grep -q 'status: running' || die "CT $CT_ID is not running"

cleanup() { pct exec "$CT_ID" -- rm -rf "$VALIDATION_DIR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log_info "STEP 18A - FRIGATE STABLE UPGRADE PREFLIGHT"
CURRENT_IMAGE="$(pct exec "$CT_ID" -- docker inspect frigate --format '{{.Config.Image}}')"
CURRENT_VERSION="$(pct exec "$CT_ID" -- curl -fsS http://127.0.0.1:5000/api/version)"
HEALTH="$(pct exec "$CT_ID" -- docker inspect frigate --format '{{.State.Health.Status}}')"
TARGET_IMAGE="ghcr.io/blakeblackshear/frigate:${TARGET_VERSION}"
log_info "Current image: ${CURRENT_IMAGE}"
log_info "Current API version: ${CURRENT_VERSION}"
log_info "Target image: ${TARGET_IMAGE}"
[[ "$HEALTH" == healthy ]] || die "Frigate is not healthy: $HEALTH"

pct exec "$CT_ID" -- test -f "$COMPOSE_FILE" || die "Compose file missing"
pct exec "$CT_ID" -- test -f "$CONFIG_DIR/config.yml" || die "Config file missing"
pct exec "$CT_ID" -- sh -c "cd '$APP_DIR' && docker compose config --quiet" \
  || die "Current Compose file is invalid"

CONFIG_BYTES="$(pct exec "$CT_ID" -- du -sb "$CONFIG_DIR" | awk '{print $1}')"
FREE_BYTES="$(pct exec "$CT_ID" -- df -P -B1 "$APP_DIR" | awk 'NR==2 {print $4}')"
REQUIRED_BYTES=$((CONFIG_BYTES * 3 + 268435456))
log_info "Config size: ${CONFIG_BYTES} bytes; CT free: ${FREE_BYTES} bytes"
(( FREE_BYTES >= REQUIRED_BYTES )) || die "Insufficient CT space for backup and validation"

if (( SKIP_PULL == 1 )); then
  pct exec "$CT_ID" -- docker image inspect "$TARGET_IMAGE" >/dev/null \
    || die "Target image is not local; rerun without --skip-pull after stable release verification"
  log_info "Using existing local target image"
else
  log_info "Pulling target image only; the running container is not changed"
  pct exec "$CT_ID" -- docker pull "$TARGET_IMAGE" >/dev/null
fi

TARGET_REPO_TAGS="$(pct exec "$CT_ID" -- docker image inspect "$TARGET_IMAGE" --format '{{join .RepoTags " "}}')"
grep -qw "$TARGET_IMAGE" <<< "$TARGET_REPO_TAGS" || die "Pulled image does not expose the exact target tag"

pct exec "$CT_ID" -- mkdir -m 700 "$VALIDATION_DIR"
pct exec "$CT_ID" -- cp "$CONFIG_DIR/config.yml" "$VALIDATION_DIR/config.yml"
pct exec "$CT_ID" -- chmod 600 "$VALIDATION_DIR/config.yml"
log_info "Validating copied config with exact target image"
pct exec "$CT_ID" -- docker run --rm -v "$VALIDATION_DIR:/config" \
  --entrypoint python3 "$TARGET_IMAGE" -u -m frigate --validate-config >/dev/null \
  || die "Target image rejected the copied Frigate config"

log_info "Preflight passed"
log_info "No Compose, config, database, container, or media state was changed"
