#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

if [[ -f "${PROJECT_ROOT}/config/local.conf" ]]; then
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/config/local.conf"
fi

log_info "=============================================="
log_info "STEP 10K - HOME ASSISTANT HACS BOOTSTRAP"
log_info "=============================================="

MODE="apply"
if [[ $# -gt 1 ]]; then
  log_error "Usage: $0 [--dry-run]"
  exit 2
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --help|-h) log_info "Usage: $0 [--dry-run]"; exit 0 ;;
    *) log_error "Usage: $0 [--dry-run]"; exit 2 ;;
  esac
fi

HA_VM_ID="${HA_VM_ID:-100}"
HACS_APP_REPOSITORY="${HACS_APP_REPOSITORY:-https://github.com/hacs/addons}"
HACS_APP_SLUG="${HACS_APP_SLUG:-get}"

VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0

record_error() {
  log_error "$1"
  ((VALIDATION_ERRORS+=1))
}

record_warn() {
  log_warn "$1"
  ((VALIDATION_WARNINGS+=1))
}

check_host_command() {
  local cmd="$1"

  if command -v "${cmd}" >/dev/null 2>&1; then
    log_info "Host command found: ${cmd}"
  else
    record_error "Required host command not found: ${cmd}"
  fi
}

guest_ha() {
  qm guest exec "${HA_VM_ID}" -- /usr/bin/ha "$@" 2>&1
}

guest_shell() {
  qm guest exec "${HA_VM_ID}" -- /bin/bash -c "$1" 2>&1
}

guest_command_succeeded() {
  grep -q '"exitcode"[[:space:]]*:[[:space:]]*0' <<< "$1" \
    && ! grep -q 'result.*error' <<< "$1"
}

validate_configuration() {
  [[ "${HA_VM_ID}" =~ ^[1-9][0-9]*$ ]] || { log_error "HA_VM_ID must be a positive integer"; return 1; }
  [[ "${HACS_APP_REPOSITORY}" == https://github.com/hacs/addons ]] \
    || { log_error "HACS_APP_REPOSITORY must be https://github.com/hacs/addons"; return 1; }
  [[ "${HACS_APP_SLUG}" =~ ^[A-Za-z0-9_-]+$ ]] \
    || { log_error "HACS_APP_SLUG contains unsupported characters"; return 1; }
}

log_guest_error() {
  local output="$1"
  log_error "Home Assistant guest command failed"
  sed -n 's/.*"err-data"[[:space:]]*:[[:space:]]*"\([^"].*\)".*/\1/p' <<< "${output}" \
    | sed 's/\\n/ /g; s/\\"/"/g' \
    | head -c 500 \
    | while IFS= read -r line; do log_error "${line}"; done
}

if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required host commands..."
for cmd in qm grep sed head; do
  check_host_command "${cmd}"
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  exit 1
fi

if ! validate_configuration; then
  exit 2
fi

if [[ "${MODE}" == "dry-run" ]]; then
  log_info "Dry run: no qm guest command will be sent and no VM state will be changed"
  log_info "Would ensure the official HACS app repository is configured: ${HACS_APP_REPOSITORY}"
  log_info "Would reload the Home Assistant app store and try app slug: ${HACS_APP_SLUG}"
  log_info "If the app is unavailable, would install the official HACS integration release ZIP transactionally"
  log_info "Would request a Home Assistant Core restart after installation"
  log_info "No changes were made"
  exit 0
fi

log_info "Checking Home Assistant VM ${HA_VM_ID}..."
if ! VM_STATUS="$(qm status "${HA_VM_ID}" 2>&1)"; then
  log_error "Could not query Home Assistant VM ${HA_VM_ID} status: ${VM_STATUS}"
  exit 1
elif [[ "${VM_STATUS}" != *'status: running'* ]]; then
  log_error "Home Assistant VM ${HA_VM_ID} is not running"
  exit 1
fi

log_info "Adding HACS app repository if needed..."
REPOSITORY_RESULT="$(guest_ha store add "${HACS_APP_REPOSITORY}" --raw-json || true)"
if guest_command_succeeded "${REPOSITORY_RESULT}" || grep -q 'already in the store' <<< "${REPOSITORY_RESULT}"; then
  log_info "HACS app repository is configured"
else
  log_guest_error "${REPOSITORY_RESULT}"
  exit 1
fi

log_info "Refreshing Home Assistant app store..."
RELOAD_RESULT="$(guest_ha store reload --raw-json || true)"
if guest_command_succeeded "${RELOAD_RESULT}"; then
  log_info "Home Assistant app store refreshed"
else
  log_guest_error "${RELOAD_RESULT}"
  exit 1
fi

HACS_INSTALLED=0
log_info "Installing the official Get HACS app..."
INSTALL_RESULT="$(guest_ha store apps install "${HACS_APP_SLUG}" --no-progress --raw-json || true)"
if guest_command_succeeded "${INSTALL_RESULT}" || grep -q 'already installed' <<< "${INSTALL_RESULT}"; then
  log_info "Get HACS app is installed"
  HACS_INSTALLED=1
else
  log_warn "Get HACS app is not available through the Supervisor CLI; using the official HACS release fallback"
  HACS_INSTALL_COMMAND="$(cat <<'REMOTE_COMMAND'
set -eu
docker exec homeassistant /bin/sh -c '
  set -eu
  config_dir=/config
  hacs_dir="$config_dir/custom_components/hacs"
  if [ -f "$hacs_dir/manifest.json" ] && [ -f "$hacs_dir/config_flow.py" ]; then
    echo "HACS integration already installed"
    exit 0
  fi
  work_dir=$(mktemp -d)
  mkdir -p "$config_dir/custom_components"
  stage_dir=$(mktemp -d "$config_dir/custom_components/.hacs-stage.XXXXXX")
  backup_dir="$work_dir/hacs.previous"
  cleanup() {
    if [ -e "$backup_dir" ] && [ ! -e "$hacs_dir" ]; then
      mv "$backup_dir" "$hacs_dir" || echo "WARNING: could not restore previous HACS directory"
    fi
    rm -rf "$stage_dir" "$work_dir"
  }
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  command -v curl >/dev/null 2>&1
  command -v unzip >/dev/null 2>&1
  mkdir -p "$work_dir/extracted"
  curl -fsSL --connect-timeout 10 --max-time 120 \
    https://github.com/hacs/integration/releases/latest/download/hacs.zip -o "$work_dir/hacs.zip"
  unzip -tq "$work_dir/hacs.zip" >/dev/null
  unzip -q "$work_dir/hacs.zip" -d "$work_dir/extracted"
  test -f "$work_dir/extracted/manifest.json"
  test -f "$work_dir/extracted/config_flow.py"
  cp -a "$work_dir/extracted/." "$stage_dir/"
  if [ -e "$hacs_dir" ]; then mv "$hacs_dir" "$backup_dir"; fi
  if ! mv "$stage_dir" "$hacs_dir"; then
    if [ -e "$backup_dir" ]; then mv "$backup_dir" "$hacs_dir"; fi
    echo "Could not activate staged HACS integration" >&2
    exit 1
  fi
  echo "HACS integration installed from the official release"
'
REMOTE_COMMAND
  )"
  HACS_RELEASE_RESULT="$(guest_shell "${HACS_INSTALL_COMMAND}" || true)"

  if grep -Eq 'HACS integration (installed|already installed)' <<< "${HACS_RELEASE_RESULT}"; then
    log_info "HACS integration installed from the official release"
    HACS_INSTALLED=1
  else
    log_guest_error "${HACS_RELEASE_RESULT}"
    record_error "Could not install HACS through the Supervisor app or official release fallback"
  fi
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "HACS bootstrap could not complete"
  exit 1
fi

if [[ "${HACS_INSTALLED}" -eq 1 ]]; then
  log_info "HACS installation is ready for Home Assistant Core"
fi

log_info "Restarting Home Assistant Core so HACS can be configured..."
RESTART_RESULT="$(guest_ha core restart --raw-json || true)"
if guest_command_succeeded "${RESTART_RESULT}"; then
  log_info "Home Assistant Core restart requested"
else
  log_guest_error "${RESTART_RESULT}"
  record_error "Could not restart Home Assistant Core"
fi

log_info "=============================================="
log_info "HOME ASSISTANT HACS BOOTSTRAP SUMMARY"
log_info "=============================================="
log_info "Validation warnings: ${VALIDATION_WARNINGS}"
log_info "Validation errors: ${VALIDATION_ERRORS}"

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "HACS bootstrap completed with errors"
  exit 1
fi

if [[ "${VALIDATION_WARNINGS}" -gt 0 ]]; then
  log_warn "HACS bootstrap completed with warnings"
else
  log_info "HACS bootstrap completed successfully"
fi

log_info "Complete the one-time HACS GitHub device authorization in Home Assistant"
