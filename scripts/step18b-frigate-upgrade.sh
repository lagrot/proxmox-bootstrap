#!/usr/bin/env bash
set -euo pipefail
umask 0077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"
STEP18_SCRIPT_DIR="${PROJECT_ROOT}/scripts"

CT_ID="${DOCKER_CT_ID:-200}"
APP_DIR="${FRIGATE_APP_DIR:-/opt/frigate}"
CONFIG_DIR="${FRIGATE_CONFIG_DIR:-${APP_DIR}/config}"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
BACKUP_ROOT="${FRIGATE_UPGRADE_BACKUP_ROOT:-/var/lib/frigate-upgrades}"
TARGET_VERSION=""
RELEASE_NOTES_REVIEWED=0
CONFIRM_UPGRADE=0
DRY_RUN=0
SKIP_PULL=0
FRIGATE_STOPPED=0
COMPOSE_CHANGED=0

usage() {
  cat <<EOF
Usage: $0 --target X.Y.Z --release-notes-reviewed [options]

Options:
  --dry-run          Run preflight and print all mutating actions only.
  --skip-pull        Require the exact target image to exist locally.
  --confirm-upgrade  Required for a real upgrade.
EOF
}

while (($#)); do
  case "$1" in
    --target) [[ $# -ge 2 ]] || die "--target requires a version"; TARGET_VERSION="$2"; shift 2 ;;
    --release-notes-reviewed) RELEASE_NOTES_REVIEWED=1; shift ;;
    --confirm-upgrade) CONFIRM_UPGRADE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --skip-pull) SKIP_PULL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "Run as root"
[[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Target must be an exact stable X.Y.Z version"
(( RELEASE_NOTES_REVIEWED == 1 )) || die "Pass --release-notes-reviewed"
for cmd in pct grep awk date; do command -v "$cmd" >/dev/null || die "Missing command: $cmd"; done
pct status "$CT_ID" | grep -q 'status: running' || die "CT $CT_ID is not running"

PREFLIGHT_ARGS=(--target "$TARGET_VERSION" --release-notes-reviewed)
(( SKIP_PULL == 1 )) && PREFLIGHT_ARGS+=(--skip-pull)
log_info "Running mandatory Step 18A preflight"
bash "${STEP18_SCRIPT_DIR}/step18a-frigate-upgrade-preflight.sh" "${PREFLIGHT_ARGS[@]}"

CURRENT_IMAGE="$(pct exec "$CT_ID" -- docker inspect frigate --format '{{.Config.Image}}')"
CURRENT_VERSION_FULL="$(pct exec "$CT_ID" -- curl -fsS http://127.0.0.1:5000/api/version)"
CURRENT_VERSION="${CURRENT_VERSION_FULL%%-*}"
TARGET_IMAGE="ghcr.io/blakeblackshear/frigate:${TARGET_VERSION}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-${CURRENT_VERSION}-to-${TARGET_VERSION}"
BACKUP_DIR="${BACKUP_ROOT}/${RUN_ID}"

if (( DRY_RUN == 1 )); then
  log_info "STEP 18B DRY RUN"
  log_info "Would stop Frigate cleanly"
  log_info "Would create protected backup: ${BACKUP_DIR}"
  log_info "Would archive ${CONFIG_DIR} and ${COMPOSE_FILE}"
  log_info "Would record current image ${CURRENT_IMAGE} and target ${TARGET_IMAGE}"
  log_info "Would generate and verify SHA256SUMS before changing Compose"
  log_info "Would replace only the Frigate image tag in Compose"
  log_info "Would validate Compose, start Frigate, wait for health, and verify API version"
  log_info "Would preserve the backup and previous image for Step 18D rollback"
  log_info "Dry run completed; no runtime state was changed"
  exit 0
fi

(( CONFIRM_UPGRADE == 1 )) || die "Real upgrade requires --confirm-upgrade"
[[ "$CURRENT_VERSION" != "$TARGET_VERSION" ]] || die "Refusing a real same-version upgrade"

cleanup() {
  if (( FRIGATE_STOPPED == 1 && COMPOSE_CHANGED == 0 )); then
    log_warn "Attempting to restart the unchanged Frigate service after an interrupted upgrade"
    pct exec "$CT_ID" -- sh -c "cd '$APP_DIR' && docker compose up -d frigate" >/dev/null 2>&1 || true
  elif (( FRIGATE_STOPPED == 1 )); then
    log_error "Upgrade stopped after Compose changed; restore backup with Step 18D: ${BACKUP_DIR}"
  fi
}
trap cleanup EXIT

log_info "Creating protected upgrade directory"
pct exec "$CT_ID" -- mkdir -p -m 700 "$BACKUP_DIR"

log_info "Stopping Frigate for a consistent database/config backup"
pct exec "$CT_ID" -- sh -c "cd '$APP_DIR' && docker compose stop frigate"
FRIGATE_STOPPED=1

log_info "Archiving Compose and complete Frigate config"
pct exec "$CT_ID" -- tar -C / -czf "$BACKUP_DIR/frigate-config.tar.gz" \
  "${COMPOSE_FILE#/}" "${CONFIG_DIR#/}"
pct exec "$CT_ID" -- sh -c "cat > '$BACKUP_DIR/upgrade.env' <<EOF
RUN_ID='$RUN_ID'
OLD_VERSION='$CURRENT_VERSION'
OLD_IMAGE='$CURRENT_IMAGE'
TARGET_VERSION='$TARGET_VERSION'
TARGET_IMAGE='$TARGET_IMAGE'
COMPOSE_FILE='$COMPOSE_FILE'
CONFIG_DIR='$CONFIG_DIR'
EOF
cd '$BACKUP_DIR' && sha256sum frigate-config.tar.gz upgrade.env > SHA256SUMS && sha256sum -c SHA256SUMS"
pct exec "$CT_ID" -- chmod 600 "$BACKUP_DIR/frigate-config.tar.gz" "$BACKUP_DIR/upgrade.env" "$BACKUP_DIR/SHA256SUMS"
pct exec "$CT_ID" -- tar -tzf "$BACKUP_DIR/frigate-config.tar.gz" >/dev/null \
  || die "Backup archive failed its read test; Compose was not changed"

log_info "Changing only the pinned Frigate image tag"
pct exec "$CT_ID" -- python3 - "$COMPOSE_FILE" "$CURRENT_IMAGE" "$TARGET_IMAGE" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
old = sys.argv[2]
new = sys.argv[3]
content = path.read_text(encoding="utf-8")
needle = f"image: {old}"
if content.count(needle) != 1:
    raise SystemExit("expected exactly one current Frigate image entry")
path.write_text(content.replace(needle, f"image: {new}"), encoding="utf-8")
PY
COMPOSE_CHANGED=1
pct exec "$CT_ID" -- sh -c "cd '$APP_DIR' && docker compose config --quiet"

log_info "Starting exact target image"
pct exec "$CT_ID" -- sh -c "cd '$APP_DIR' && docker compose up -d frigate"
FRIGATE_STOPPED=0

HEALTH=""
for _ in $(seq 1 60); do
  HEALTH="$(pct exec "$CT_ID" -- docker inspect frigate --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  [[ "$HEALTH" == healthy ]] && break
  sleep 2
done
[[ "$HEALTH" == healthy ]] || die "Target Frigate did not become healthy; use Step 18D with ${BACKUP_DIR}"

ACTUAL_VERSION="$(pct exec "$CT_ID" -- curl -fsS http://127.0.0.1:5000/api/version)"
[[ "${ACTUAL_VERSION%%-*}" == "$TARGET_VERSION" ]] || die "Expected ${TARGET_VERSION}, API reports ${ACTUAL_VERSION}"
log_info "Upgrade executor completed; backup retained at ${BACKUP_DIR}"
log_info "Run Step 18C validation before accepting the upgrade"
