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

log_guest_error() {
  local output="$1"
  log_error "Home Assistant guest command failed"
  sed -n 's/.*"err-data"[[:space:]]*:[[:space:]]*"\([^"].*\)".*/\1/p' <<< "${output}" \
    | sed 's/\\n/ /g; s/\\"/"/g' \
    | head -c 500 \
    | while IFS= read -r line; do log_error "${line}"; done
}

log_info "Checking Home Assistant VM ${HA_VM_ID}..."
if ! qm status "${HA_VM_ID}" 2>/dev/null | grep -q 'status: running'; then
  record_error "Home Assistant VM ${HA_VM_ID} is not running"
fi

log_info "Checking required host commands..."
for cmd in qm grep sed head; do
  check_host_command "${cmd}"
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
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
  trap "rm -rf \"$work_dir\"" EXIT
  mkdir -p "$work_dir/extracted" "$config_dir/custom_components"
  curl -fsSL https://github.com/hacs/integration/releases/latest/download/hacs.zip -o "$work_dir/hacs.zip"
  unzip -q "$work_dir/hacs.zip" -d "$work_dir/extracted"
  test -f "$work_dir/extracted/manifest.json"
  test -f "$work_dir/extracted/config_flow.py"
  rm -rf "$hacs_dir"
  mkdir -p "$hacs_dir"
  cp -a "$work_dir/extracted/." "$hacs_dir/"
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
