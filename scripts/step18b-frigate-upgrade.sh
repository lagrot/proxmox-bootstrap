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
COMPOSE_HELPER="${PROJECT_ROOT}/lib/frigate-upgrade-compose.py"
TARGET_VERSION=""
TARGET_SET=0
RELEASE_NOTES_REVIEWED=0
CONFIRM_UPGRADE=0
DRY_RUN=0
SKIP_PULL=0
FRIGATE_STOPPED=0
BACKUP_CREATED=0
COMPOSE_HELPER_TEXT=""

usage() {
  cat <<EOF
Usage: $0 --target X.Y.Z --release-notes-reviewed [options]

Options:
  --dry-run          Run non-mutating preflight and print planned actions.
  --skip-pull        Require the exact target image to exist locally.
  --confirm-upgrade  Required for a real upgrade.
EOF
}

while (($#)); do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || die "--target requires a version"
      (( TARGET_SET == 0 )) || die "--target may only be provided once"
      TARGET_VERSION="$2"; TARGET_SET=1; shift 2 ;;
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
[[ "$CT_ID" =~ ^[0-9]+$ ]] || die "Frigate CT ID must be numeric"
[[ "$BACKUP_ROOT" == /* && "$APP_DIR" == /* && "$CONFIG_DIR" == /* ]] || die "Frigate paths must be absolute"
for path_value in "$BACKUP_ROOT" "$APP_DIR" "$CONFIG_DIR"; do
  [[ "$path_value" != *"'"* && "$path_value" != *"="* && "$path_value" != *$'\n'* ]] \
    || die "Frigate paths cannot contain quotes, equals signs, or line breaks"
done
[[ -f "$COMPOSE_HELPER" ]] || die "Missing Compose helper: $COMPOSE_HELPER"
CT_STATUS="$(pct status "$CT_ID" 2>&1)" || die "Could not query CT $CT_ID status: $CT_STATUS"
[[ "$CT_STATUS" == *'status: running'* ]] || die "CT $CT_ID is not running"

# A dry run must never pull or retag an image. Stage 18A must have prepared it.
if (( DRY_RUN == 1 )); then SKIP_PULL=1; fi

PREFLIGHT_ARGS=(--target "$TARGET_VERSION" --release-notes-reviewed)
(( SKIP_PULL == 1 )) && PREFLIGHT_ARGS+=(--skip-pull)
log_info "Running mandatory Step 18A preflight"
bash "${STEP18_SCRIPT_DIR}/step18a-frigate-upgrade-preflight.sh" "${PREFLIGHT_ARGS[@]}"

CURRENT_IMAGE="$(pct exec "$CT_ID" -- docker inspect frigate --format '{{.Config.Image}}')"
CURRENT_VERSION_FULL="$(pct exec "$CT_ID" -- curl -fsS http://127.0.0.1:5000/api/version)"
CURRENT_VERSION="${CURRENT_VERSION_FULL%%-*}"
TARGET_IMAGE="ghcr.io/blakeblackshear/frigate:${TARGET_VERSION}"
[[ "$CURRENT_IMAGE" == "ghcr.io/blakeblackshear/frigate:${CURRENT_VERSION}" ]] \
  || die "Running image is not the exact official stable image for API version ${CURRENT_VERSION}"
[[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Current API version is not exact X.Y.Z"
RUN_ID="$(date +%Y%m%d-%H%M%S%N)-${CURRENT_VERSION}-to-${TARGET_VERSION}"
BACKUP_DIR="${BACKUP_ROOT}/${RUN_ID}"

COMPOSE_HELPER_TEXT="$(<"${COMPOSE_HELPER}")"
if ! pct exec "$CT_ID" -- python3 -c "$COMPOSE_HELPER_TEXT" \
  "$COMPOSE_FILE" --check-image "$CURRENT_IMAGE" >/dev/null; then
  die "Compose must contain exactly one image entry for the running Frigate image"
fi

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
  log_info "The target image must already be local; Step 18A performs any required pull"
  log_info "Dry run completed; no runtime state was changed"
  exit 0
fi

(( CONFIRM_UPGRADE == 1 )) || die "Real upgrade requires --confirm-upgrade"
[[ "$CURRENT_VERSION" != "$TARGET_VERSION" ]] || die "Refusing a real same-version upgrade"

cleanup() {
  if (( FRIGATE_STOPPED == 1 )); then
    if pct exec "$CT_ID" -- python3 -c "$COMPOSE_HELPER_TEXT" \
      "$COMPOSE_FILE" --check-image "$CURRENT_IMAGE" >/dev/null 2>&1; then
      log_warn "Attempting to restart Frigate with its unchanged image after an interrupted upgrade"
      pct exec "$CT_ID" -- docker compose --project-directory "$APP_DIR" \
        -f "$COMPOSE_FILE" up -d frigate >/dev/null 2>&1 \
        || log_error "Restart failed; check CT 200 and run the recovery procedure"
    else
      log_error "Compose no longer references the old image; leave Frigate stopped and use Step 18D: ${BACKUP_DIR}"
    fi
  elif (( BACKUP_CREATED == 1 )); then
    pct exec "$CT_ID" -- rm -rf -- "$BACKUP_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log_info "Creating a new protected upgrade directory"
pct exec "$CT_ID" -- mkdir -p -m 700 "$BACKUP_ROOT"
pct exec "$CT_ID" -- mkdir -m 700 "$BACKUP_DIR"
BACKUP_CREATED=1

log_info "Stopping Frigate for a consistent database/config backup"
FRIGATE_STOPPED=1
pct exec "$CT_ID" -- docker compose --project-directory "$APP_DIR" \
  -f "$COMPOSE_FILE" stop frigate

log_info "Archiving Compose and complete Frigate config"
pct exec "$CT_ID" -- tar -C / -czf "$BACKUP_DIR/frigate-config.tar.gz" \
  "${COMPOSE_FILE#/}" "${CONFIG_DIR#/}"
pct exec "$CT_ID" -- python3 - "$BACKUP_DIR/upgrade.env" \
  "$RUN_ID" "$CURRENT_VERSION" "$CURRENT_IMAGE" "$TARGET_VERSION" \
  "$TARGET_IMAGE" "$COMPOSE_FILE" "$CONFIG_DIR" <<'PY'
import os
import sys

path, run_id, old_version, old_image, target_version, target_image, compose_file, config_dir = sys.argv[1:]
fields = {
    "RUN_ID": run_id, "OLD_VERSION": old_version, "OLD_IMAGE": old_image,
    "TARGET_VERSION": target_version, "TARGET_IMAGE": target_image,
    "COMPOSE_FILE": compose_file, "CONFIG_DIR": config_dir,
}
if any("\n" in value or "\r" in value or "'" in value for value in fields.values()):
    raise SystemExit("unsafe character in upgrade metadata")
payload = "".join(f"{key}='{value}'\n" for key, value in fields.items()).encode()
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "wb") as stream:
    stream.write(payload)
    stream.flush()
    os.fsync(stream.fileno())
PY
pct exec "$CT_ID" -- bash -c 'cd -- "$1" && sha256sum frigate-config.tar.gz upgrade.env > SHA256SUMS && sha256sum -c SHA256SUMS' \
  bash "$BACKUP_DIR"
pct exec "$CT_ID" -- chmod 600 "$BACKUP_DIR/frigate-config.tar.gz" "$BACKUP_DIR/upgrade.env" "$BACKUP_DIR/SHA256SUMS"
pct exec "$CT_ID" -- tar -tzf "$BACKUP_DIR/frigate-config.tar.gz" >/dev/null \
  || die "Backup archive failed its read test; Compose was not changed"

log_info "Changing only the pinned Frigate image tag"
pct exec "$CT_ID" -- python3 -c "$COMPOSE_HELPER_TEXT" \
  "$COMPOSE_FILE" --replace-image "$CURRENT_IMAGE" "$TARGET_IMAGE"
pct exec "$CT_ID" -- docker compose --project-directory "$APP_DIR" \
  -f "$COMPOSE_FILE" config --quiet

log_info "Starting exact target image"
pct exec "$CT_ID" -- docker compose --project-directory "$APP_DIR" \
  -f "$COMPOSE_FILE" up -d frigate
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
