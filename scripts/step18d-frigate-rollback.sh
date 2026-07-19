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
DRY_RUN=0
RESTORE_TEST=0
CONFIRM_ROLLBACK=0
STAGING_DIR=""

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
    --backup-dir) [[ $# -ge 2 ]] || die "--backup-dir requires a path"; BACKUP_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --restore-test) RESTORE_TEST=1; shift ;;
    --confirm-rollback) CONFIRM_ROLLBACK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in pct grep awk date; do command -v "$cmd" >/dev/null || die "Missing command: $cmd"; done
case "$BACKUP_DIR" in /var/lib/frigate-upgrades/*) ;; *) die "Unexpected backup path: ${BACKUP_DIR:-empty}" ;; esac
MODE_COUNT=$((DRY_RUN + RESTORE_TEST + CONFIRM_ROLLBACK))
(( MODE_COUNT == 1 )) || die "Choose exactly one mode"
pct status "$CT_ID" | grep -q 'status: running' || die "CT $CT_ID is not running"

for file in SHA256SUMS upgrade.env frigate-config.tar.gz; do
  pct exec "$CT_ID" -- test -f "$BACKUP_DIR/$file" || die "Backup file missing: $file"
done
log_info "Validating backup checksums and archive"
pct exec "$CT_ID" -- sh -c "cd '$BACKUP_DIR' && sha256sum -c SHA256SUMS && tar -tzf frigate-config.tar.gz >/dev/null" \
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

STAGING_DIR="/tmp/frigate-rollback-$RANDOM"
cleanup() { pct exec "$CT_ID" -- rm -rf "$STAGING_DIR" >/dev/null 2>&1 || true; }
trap cleanup EXIT
pct exec "$CT_ID" -- mkdir -m 700 "$STAGING_DIR"
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

RUN_ID="$(date +%Y%m%d-%H%M%S)"
FAILED_ARCHIVE="$BACKUP_DIR/pre-rollback-current-${RUN_ID}.tar.gz"
FAILED_CONFIG_DIR="${CONFIG_DIR}.failed-${RUN_ID}"
log_info "Stopping Frigate for explicit rollback"
pct exec "$CT_ID" -- sh -c "cd '$APP_DIR' && docker compose stop frigate"
log_info "Preserving current failed state"
pct exec "$CT_ID" -- tar -C / -czf "$FAILED_ARCHIVE" "${COMPOSE_FILE#/}" "${CONFIG_DIR#/}"
pct exec "$CT_ID" -- chmod 600 "$FAILED_ARCHIVE"
pct exec "$CT_ID" -- tar -tzf "$FAILED_ARCHIVE" >/dev/null || die "Failed-state archive is unreadable; rollback stopped"

log_info "Installing matching old Compose and config/database"
pct exec "$CT_ID" -- mv "$CONFIG_DIR" "$FAILED_CONFIG_DIR"
pct exec "$CT_ID" -- cp -a "$STAGING_DIR/${CONFIG_DIR#/}" "$CONFIG_DIR"
pct exec "$CT_ID" -- cp -a "$STAGING_DIR/${COMPOSE_FILE#/}" "$COMPOSE_FILE"
pct exec "$CT_ID" -- sh -c "cd '$APP_DIR' && docker compose config --quiet && docker compose up -d frigate"

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
log_info "Rollback completed and validated; failed state retained at $FAILED_CONFIG_DIR"
