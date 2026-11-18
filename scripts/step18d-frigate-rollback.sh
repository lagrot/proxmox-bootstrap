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
BACKUP_DIR=""
BACKUP_SET=0
DRY_RUN=0
RESTORE_TEST=0
CONFIRM_ROLLBACK=0
STAGING_DIR=""
KEEP_STAGING=0
ARCHIVE_HELPER_TEXT=""

usage() {
  cat <<EOF
Usage: $0 --backup-dir /var/lib/frigate-upgrades/RUN [mode]

Modes:
  --dry-run          Validate backup and describe rollback; change nothing.
  --restore-test     Extract and inspect backup in temporary storage only.
  --confirm-rollback Perform the explicit production rollback.
EOF
}

while (($#)); do
  case "$1" in
    --backup-dir)
      [[ $# -ge 2 ]] || die "--backup-dir requires a path"
      (( BACKUP_SET == 0 )) || die "--backup-dir may only be provided once"
      BACKUP_DIR="$2"; BACKUP_SET=1; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --restore-test) RESTORE_TEST=1; shift ;;
    --confirm-rollback) CONFIRM_ROLLBACK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in pct grep awk date; do command -v "$cmd" >/dev/null || die "Missing command: $cmd"; done
[[ "$CT_ID" =~ ^[0-9]+$ ]] || die "Frigate CT ID must be numeric"
[[ "$APP_DIR" == /* && "$CONFIG_DIR" == /* ]] || die "Frigate paths must be absolute"
[[ "$BACKUP_DIR" =~ ^/var/lib/frigate-upgrades/[0-9]{8}-[0-9]{6}([0-9]{9})?-[0-9]+\.[0-9]+\.[0-9]+-to-[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "Unexpected managed backup path: ${BACKUP_DIR:-empty}"
MODE_COUNT=$((DRY_RUN + RESTORE_TEST + CONFIRM_ROLLBACK))
(( MODE_COUNT == 1 )) || die "Choose exactly one mode"
if ! CT_STATUS="$(pct status "$CT_ID" 2>&1)"; then
  die "Could not query CT $CT_ID status: $CT_STATUS"
fi
[[ "$CT_STATUS" == *'status: running'* ]] || die "CT $CT_ID is not running"

for file in SHA256SUMS upgrade.env frigate-config.tar.gz; do
  pct exec "$CT_ID" -- test -f "$BACKUP_DIR/$file" || die "Backup file missing: $file"
done
log_info "Validating backup checksums and archive"
pct exec "$CT_ID" -- test ! -L "$BACKUP_DIR" || die "Backup directory must not be a symlink"
pct exec "$CT_ID" -- bash -c 'cd -- "$1" && sha256sum -c SHA256SUMS && tar -tzf frigate-config.tar.gz >/dev/null' \
  bash "$BACKUP_DIR" \
  || die "Backup integrity validation failed"

metadata() {
  local key="$1"
  pct exec "$CT_ID" -- awk -F= -v key="$key" '$1 == key {value=$2; gsub(/^\047|\047$/, "", value); print value}' "$BACKUP_DIR/upgrade.env"
}
OLD_VERSION="$(metadata OLD_VERSION)"
OLD_IMAGE="$(metadata OLD_IMAGE)"
TARGET_VERSION="$(metadata TARGET_VERSION)"
BACKUP_COMPOSE="$(metadata COMPOSE_FILE)"
BACKUP_CONFIG="$(metadata CONFIG_DIR)"

[[ "$OLD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid old version metadata"
[[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid target version metadata"
[[ "$OLD_IMAGE" == "ghcr.io/blakeblackshear/frigate:${OLD_VERSION}" ]] || die "Old image metadata is not exact"
[[ "$BACKUP_COMPOSE" == "$COMPOSE_FILE" ]] || die "Backup Compose path does not match this deployment"
[[ "$BACKUP_CONFIG" == "$CONFIG_DIR" ]] || die "Backup config path does not match this deployment"
pct exec "$CT_ID" -- docker image inspect "$OLD_IMAGE" >/dev/null || die "Old exact image is not local: $OLD_IMAGE"

ARCHIVE_HELPER="${PROJECT_ROOT}/lib/frigate-upgrade-archive.py"
[[ -f "$ARCHIVE_HELPER" ]] || die "Missing archive safety helper: $ARCHIVE_HELPER"
ARCHIVE_HELPER_TEXT="$(<"$ARCHIVE_HELPER")"
pct exec "$CT_ID" -- python3 -c "$ARCHIVE_HELPER_TEXT" \
  "$BACKUP_DIR/frigate-config.tar.gz" "${COMPOSE_FILE#/}" "${CONFIG_DIR#/}" \
  || die "Backup archive contains unsafe or unexpected entries"

log_info "Rollback source: target ${TARGET_VERSION} back to ${OLD_VERSION}"
log_info "Rollback image: ${OLD_IMAGE}"

if (( DRY_RUN == 1 )); then
  log_info "Would extract and verify the backup in protected staging"
  log_info "Would stop Frigate and archive the current failed state"
  log_info "Would restore matching Compose and complete config/database"
  log_info "Would preserve media, the upgrade backup, and failed-state archive"
  log_info "Would start ${OLD_IMAGE}, verify health/API, and run Step 18C baseline validation"
  log_info "Dry run completed; no runtime state was changed"
  exit 0
fi

STAGING_DIR="$(pct exec "$CT_ID" -- mktemp -d /tmp/frigate-rollback.XXXXXXXXXX)"
[[ "$STAGING_DIR" =~ ^/tmp/frigate-rollback\.[A-Za-z0-9]{10}$ ]] || die "Invalid staging directory"
cleanup() {
  if (( KEEP_STAGING == 1 )); then
    log_error "Rollback is incomplete; preserve and inspect staging directory: ${STAGING_DIR}"
  elif [[ -n "$STAGING_DIR" ]]; then
    pct exec "$CT_ID" -- rm -rf -- "$STAGING_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
pct exec "$CT_ID" -- tar -xzf "$BACKUP_DIR/frigate-config.tar.gz" -C "$STAGING_DIR"
pct exec "$CT_ID" -- test -f "$STAGING_DIR/${COMPOSE_FILE#/}" || die "Restored Compose missing from staging"
pct exec "$CT_ID" -- test -f "$STAGING_DIR/${CONFIG_DIR#/}/config.yml" || die "Restored config missing from staging"
RESTORED_IMAGE="$(pct exec "$CT_ID" -- awk '/^[[:space:]]*image:/ {print $2; exit}' "$STAGING_DIR/${COMPOSE_FILE#/}")"
[[ "$RESTORED_IMAGE" == "$OLD_IMAGE" ]] || die "Staged Compose image does not match rollback metadata"

if (( RESTORE_TEST == 1 )); then
  log_info "Restore test passed in temporary staging"
  log_info "Production Compose, config, container, database, and media were not changed"
  exit 0
fi

RUN_ID="$(date +%Y%m%d-%H%M%S%N)"
FAILED_ARCHIVE="$BACKUP_DIR/pre-rollback-current-${RUN_ID}.tar.gz"
FAILED_CONFIG_DIR="${CONFIG_DIR}.failed-${RUN_ID}"
if ! pct exec "$CT_ID" -- test ! -e "$FAILED_ARCHIVE" \
  || ! pct exec "$CT_ID" -- test ! -e "$FAILED_CONFIG_DIR"; then
  die "Rollback run paths already exist; refusing to overwrite prior recovery state"
fi
log_info "Stopping Frigate for explicit rollback"
KEEP_STAGING=1
pct exec "$CT_ID" -- docker compose --project-directory "$APP_DIR" \
  -f "$COMPOSE_FILE" stop frigate
log_info "Preserving current failed state"
pct exec "$CT_ID" -- tar -C / -czf "$FAILED_ARCHIVE" "${COMPOSE_FILE#/}" "${CONFIG_DIR#/}"
pct exec "$CT_ID" -- chmod 600 "$FAILED_ARCHIVE"
pct exec "$CT_ID" -- tar -tzf "$FAILED_ARCHIVE" >/dev/null || die "Failed-state archive is unreadable; rollback stopped"

log_info "Installing matching old Compose and config/database"
pct exec "$CT_ID" -- mv "$CONFIG_DIR" "$FAILED_CONFIG_DIR"
pct exec "$CT_ID" -- cp -a "$STAGING_DIR/${CONFIG_DIR#/}" "$CONFIG_DIR"
pct exec "$CT_ID" -- cp -a "$STAGING_DIR/${COMPOSE_FILE#/}" "$COMPOSE_FILE"
pct exec "$CT_ID" -- docker compose --project-directory "$APP_DIR" \
  -f "$COMPOSE_FILE" config --quiet
pct exec "$CT_ID" -- docker compose --project-directory "$APP_DIR" \
  -f "$COMPOSE_FILE" up -d frigate

HEALTH=""
for _ in $(seq 1 60); do
  HEALTH="$(pct exec "$CT_ID" -- docker inspect frigate --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  [[ "$HEALTH" == healthy ]] && break
  sleep 2
done
[[ "$HEALTH" == healthy ]] || die "Rolled-back Frigate did not become healthy; failed config remains at $FAILED_CONFIG_DIR"
ACTUAL_VERSION="$(pct exec "$CT_ID" -- curl -fsS http://127.0.0.1:5000/api/version)"
[[ "${ACTUAL_VERSION%%-*}" == "$OLD_VERSION" ]] || die "Rollback API version mismatch: $ACTUAL_VERSION"

log_info "Running regression validation against restored version"
bash "${PROJECT_ROOT}/scripts/step18c-frigate-post-upgrade-validation.sh" \
  --expected-version "$OLD_VERSION" --baseline-test
KEEP_STAGING=0
log_info "Rollback completed and validated; failed state retained at $FAILED_CONFIG_DIR"
