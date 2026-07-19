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
EXPECTED_VERSION=""
BACKUP_DIR=""
BASELINE_TEST=0
RESULT_DIR=""
FAILED_TRACKS=0

usage() {
  cat <<EOF
Usage: $0 --expected-version X.Y.Z --backup-dir PATH
       $0 --expected-version X.Y.Z --baseline-test

Normal post-upgrade validation requires the matching Step 18B backup.
--baseline-test is only for testing orchestration without claiming an upgrade.
EOF
}

while (($#)); do
  case "$1" in
    --expected-version) [[ $# -ge 2 ]] || die "--expected-version requires a value"; EXPECTED_VERSION="$2"; shift 2 ;;
    --backup-dir) [[ $# -ge 2 ]] || die "--backup-dir requires a path"; BACKUP_DIR="$2"; shift 2 ;;
    --baseline-test) BASELINE_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "Run as root"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Expected version must be exact X.Y.Z"
for cmd in pct grep awk mktemp; do command -v "$cmd" >/dev/null || die "Missing command: $cmd"; done
pct status "$CT_ID" | grep -q 'status: running' || die "CT $CT_ID is not running"
if (( BASELINE_TEST == 0 )); then
  [[ -n "$BACKUP_DIR" ]] || die "Normal validation requires --backup-dir from Step 18B"
elif [[ -n "$BACKUP_DIR" ]]; then
  die "Do not combine --baseline-test with --backup-dir"
fi

RESULT_DIR="$(mktemp -d /tmp/frigate-post-upgrade.XXXXXX)"
cleanup() { rm -rf -- "$RESULT_DIR"; }
trap cleanup EXIT

log_info "STEP 18C - FRIGATE POST-UPGRADE VALIDATION"
EXPECTED_IMAGE="ghcr.io/blakeblackshear/frigate:${EXPECTED_VERSION}"
ACTUAL_IMAGE="$(pct exec "$CT_ID" -- docker inspect frigate --format '{{.Config.Image}}' 2>/dev/null || true)"
HEALTH="$(pct exec "$CT_ID" -- docker inspect frigate --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' 2>/dev/null || true)"
API_VERSION="$(pct exec "$CT_ID" -- curl -fsS --max-time 10 http://127.0.0.1:5000/api/version 2>/dev/null || true)"

[[ "$ACTUAL_IMAGE" == "$EXPECTED_IMAGE" ]] || die "Expected image $EXPECTED_IMAGE, found ${ACTUAL_IMAGE:-unknown}"
[[ "$HEALTH" == healthy ]] || die "Frigate is not healthy: ${HEALTH:-unknown}"
[[ "${API_VERSION%%-*}" == "$EXPECTED_VERSION" ]] || die "Expected API $EXPECTED_VERSION, found ${API_VERSION:-unknown}"
log_info "Exact image, API version, and health match"

if (( BASELINE_TEST == 1 )); then
  log_warn "Baseline-test mode: backup validation is intentionally skipped"
else
  case "$BACKUP_DIR" in
    /var/lib/frigate-upgrades/*) ;;
    *) die "Unexpected upgrade backup path: $BACKUP_DIR" ;;
  esac
  log_info "Validating matching Step 18B backup"
  pct exec "$CT_ID" -- test -f "$BACKUP_DIR/SHA256SUMS" || die "Backup checksum manifest missing"
  pct exec "$CT_ID" -- test -f "$BACKUP_DIR/upgrade.env" || die "Backup metadata missing"
  pct exec "$CT_ID" -- test -f "$BACKUP_DIR/frigate-config.tar.gz" || die "Backup archive missing"
  pct exec "$CT_ID" -- sh -c "cd '$BACKUP_DIR' && sha256sum -c SHA256SUMS && tar -tzf frigate-config.tar.gz >/dev/null" \
    || die "Backup integrity validation failed"
  BACKUP_TARGET="$(pct exec "$CT_ID" -- awk -F= '/^TARGET_VERSION=/ {gsub(/^\047|\047$/, "", $2); print $2}' "$BACKUP_DIR/upgrade.env")"
  [[ "$BACKUP_TARGET" == "$EXPECTED_VERSION" ]] || die "Backup target $BACKUP_TARGET does not match $EXPECTED_VERSION"
  log_info "Backup checksums, archive, and target metadata match"
fi

VALIDATORS=(
  step04b-frigate-validation.sh
  step10h-frigate-camera-validation.sh
  step10i-frigate-tpu-validation.sh
  step10j-frigate-gpu-validation.sh
  step10p-frigate-event-recording-validation.sh
  step10n-frigate-homeassistant-smoketest.sh
  step13b-frigate-media-retention-validation.sh
)

for validator in "${VALIDATORS[@]}"; do
  log_info "Running ${validator}"
  output="${RESULT_DIR}/${validator}.log"
  if bash "${STEP18_SCRIPT_DIR}/${validator}" >"$output" 2>&1; then
    log_info "PASS: ${validator}"
  else
    log_error "FAIL: ${validator}"
    tail -80 "$output"
    ((FAILED_TRACKS+=1))
  fi
done

log_info "Post-upgrade failed tracks: ${FAILED_TRACKS}"
if (( FAILED_TRACKS > 0 )); then
  log_error "Post-upgrade validation failed; evaluate Step 18D rollback"
  exit 1
fi

if (( BASELINE_TEST == 1 )); then
  log_info "Baseline orchestration test passed; no upgrade is being accepted"
else
  log_info "Post-upgrade validation passed for ${EXPECTED_VERSION}"
fi
