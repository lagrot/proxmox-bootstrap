#!/usr/bin/env bash
set -euo pipefail

# ======================================
# STEP 08D - HERMES BOOTSTRAP VALIDATION
# ======================================
#
# Read-only validation for Hermes bootstrap in CT 220.
#
# This validates the result of:
#   scripts/step08c-hermes-bootstrap.sh
#
# It does not install, modify, enable, start, stop, or restart anything.
#
# Validates:
#   - CT 220 exists and is running
#   - Hermes CLI exists at /home/hermes/.local/bin/hermes
#   - /usr/local/bin/hermes symlink exists and points to the Hermes CLI
#   - controlled PATH can find hermes
#   - hermes --help works
#   - /opt/hermes directories exist
#   - /home/hermes/.hermes exists
#   - hermes-gateway.service exists
#   - service is disabled
#   - service is inactive
#   - sudoers helper exists and validates
#   - bootstrap script does not obviously contain API keys
#   - ripgrep is installed

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

HERMES_CT_ID="${HERMES_CT_ID:-220}"
HERMES_CT_HOSTNAME="${HERMES_CT_HOSTNAME:-hermes-agent}"
HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="${HERMES_HOME:-/home/${HERMES_USER}}"
HERMES_BASE_DIR="${HERMES_BASE_DIR:-/opt/hermes}"

HERMES_LOCAL_BIN="${HERMES_HOME}/.local/bin/hermes"
HERMES_SYSTEM_BIN="/usr/local/bin/hermes"
HERMES_SERVICE_NAME="hermes-gateway.service"
HERMES_SERVICE_PATH="/etc/systemd/system/${HERMES_SERVICE_NAME}"
HERMES_SUDOERS_FILE="/etc/sudoers.d/hermes-agent-base"

BOOTSTRAP_SCRIPT="${PROJECT_ROOT}/scripts/step08c-hermes-bootstrap.sh"

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

run_in_ct() {
  pct exec "${HERMES_CT_ID}" -- bash -lc "$1"
}

check_host_command() {
  local cmd="$1"

  if command -v "${cmd}" >/dev/null 2>&1; then
    log_info "Host command found: ${cmd}"
  else
    record_error "Required host command not found: ${cmd}"
  fi
}

check_root_access() {
  log_info "Checking root access..."

  if [[ "${EUID}" -ne 0 ]]; then
    record_error "This script must be run as root"
    return
  fi

  log_info "Running as root"
}

check_required_host_commands() {
  log_info "Checking required host commands..."

  local cmd
  for cmd in pct grep awk readlink; do
    check_host_command "${cmd}"
  done
}

check_ct_exists() {
  log_info "Checking whether CT ${HERMES_CT_ID} exists..."

  if pct config "${HERMES_CT_ID}" >/dev/null 2>&1; then
    log_info "CT ${HERMES_CT_ID} exists"
  else
    record_error "CT ${HERMES_CT_ID} does not exist"
  fi
}

check_ct_running() {
  log_info "Checking whether CT ${HERMES_CT_ID} is running..."

  local status
  status="$(pct status "${HERMES_CT_ID}" 2>/dev/null | awk '{print $2}' || true)"

  if [[ "${status}" == "running" ]]; then
    log_info "CT ${HERMES_CT_ID} is running"
  else
    record_error "CT ${HERMES_CT_ID} is not running. Current status: ${status:-unknown}"
  fi
}

check_ct_identity() {
  log_info "Checking Hermes CT identity..."

  local hostname
  hostname="$(run_in_ct 'hostname' 2>/dev/null || true)"

  if [[ "${hostname}" == "${HERMES_CT_HOSTNAME}" ]]; then
    log_info "Hostname is correct: ${hostname}"
  else
    record_error "Hostname mismatch. Expected ${HERMES_CT_HOSTNAME}, got ${hostname:-unknown}"
  fi

  if run_in_ct "id '${HERMES_USER}' >/dev/null 2>&1"; then
    log_info "User exists: ${HERMES_USER}"
  else
    record_error "User does not exist: ${HERMES_USER}"
  fi
}

check_hermes_cli() {
  log_info "Checking Hermes CLI..."

  if run_in_ct "test -x '${HERMES_LOCAL_BIN}'"; then
    log_info "Hermes CLI exists and is executable: ${HERMES_LOCAL_BIN}"
  else
    record_error "Hermes CLI missing or not executable: ${HERMES_LOCAL_BIN}"
  fi

  if run_in_ct "test -L '${HERMES_SYSTEM_BIN}'"; then
    log_info "Hermes symlink exists: ${HERMES_SYSTEM_BIN}"
  else
    record_error "Hermes symlink missing: ${HERMES_SYSTEM_BIN}"
  fi

  local symlink_target
  symlink_target="$(run_in_ct "readlink -f '${HERMES_SYSTEM_BIN}' 2>/dev/null" || true)"

  if [[ "${symlink_target}" == "${HERMES_LOCAL_BIN}" ]]; then
    log_info "Hermes symlink target is correct"
  else
    record_error "Hermes symlink target mismatch. Expected ${HERMES_LOCAL_BIN}, got ${symlink_target:-unknown}"
  fi

  if run_in_ct "PATH=/usr/local/bin:/usr/bin:/bin command -v hermes >/dev/null 2>&1"; then
    log_info "Hermes is available in controlled PATH"
  else
    record_error "Hermes is not available in controlled PATH"
  fi

  if run_in_ct "PATH=/usr/local/bin:/usr/bin:/bin hermes --help >/dev/null 2>&1"; then
    log_info "Hermes CLI responds to --help"
  else
    record_error "Hermes CLI did not respond to --help"
  fi
}

check_hermes_directories() {
  log_info "Checking Hermes directories..."

  local dir
  for dir in \
    "${HERMES_BASE_DIR}" \
    "${HERMES_BASE_DIR}/workspaces" \
    "${HERMES_BASE_DIR}/logs" \
    "${HERMES_HOME}/.config" \
    "${HERMES_HOME}/.local/bin" \
    "${HERMES_HOME}/.hermes"
  do
    if run_in_ct "test -d '${dir}'"; then
      log_info "Directory exists: ${dir}"
    else
      record_error "Missing directory: ${dir}"
    fi
  done

  local owner
  owner="$(run_in_ct "stat -c '%U:%G' '${HERMES_BASE_DIR}' 2>/dev/null" || true)"

  if [[ "${owner}" == "${HERMES_USER}:${HERMES_USER}" ]]; then
    log_info "${HERMES_BASE_DIR} ownership is correct: ${owner}"
  else
    record_error "${HERMES_BASE_DIR} ownership mismatch. Expected ${HERMES_USER}:${HERMES_USER}, got ${owner:-unknown}"
  fi
}

check_systemd_service() {
  log_info "Checking Hermes systemd service..."

  if run_in_ct "test -f '${HERMES_SERVICE_PATH}'"; then
    log_info "Service file exists: ${HERMES_SERVICE_PATH}"
  else
    record_error "Service file missing: ${HERMES_SERVICE_PATH}"
  fi

  if run_in_ct "systemctl list-unit-files '${HERMES_SERVICE_NAME}' >/dev/null 2>&1"; then
    log_info "systemd knows about ${HERMES_SERVICE_NAME}"
  else
    record_error "systemd does not know about ${HERMES_SERVICE_NAME}"
  fi

  local enabled_state
  enabled_state="$(run_in_ct "systemctl is-enabled '${HERMES_SERVICE_NAME}' 2>/dev/null" || true)"

  case "${enabled_state}" in
    disabled)
      log_info "${HERMES_SERVICE_NAME} is disabled, as expected"
      ;;
    enabled)
      record_warn "${HERMES_SERVICE_NAME} is enabled. Expected disabled until provider/API-key config is ready"
      ;;
    *)
      record_warn "${HERMES_SERVICE_NAME} enabled state is: ${enabled_state:-unknown}"
      ;;
  esac

  local active_state
  active_state="$(run_in_ct "systemctl is-active '${HERMES_SERVICE_NAME}' 2>/dev/null" || true)"

  case "${active_state}" in
    inactive)
      log_info "${HERMES_SERVICE_NAME} is inactive, as expected"
      ;;
    active)
      record_warn "${HERMES_SERVICE_NAME} is active. Expected inactive until provider/API-key config is ready"
      ;;
    failed)
      record_error "${HERMES_SERVICE_NAME} is failed"
      ;;
    *)
      record_warn "${HERMES_SERVICE_NAME} active state is: ${active_state:-unknown}"
      ;;
  esac
}

check_sudoers() {
  log_info "Checking sudoers helper..."

  if run_in_ct "test -f '${HERMES_SUDOERS_FILE}'"; then
    log_info "sudoers file exists: ${HERMES_SUDOERS_FILE}"
  else
    record_error "sudoers file missing: ${HERMES_SUDOERS_FILE}"
    return
  fi

  if run_in_ct "visudo -cf '${HERMES_SUDOERS_FILE}' >/dev/null 2>&1"; then
    log_info "sudoers syntax is valid"
  else
    record_error "sudoers syntax validation failed for ${HERMES_SUDOERS_FILE}"
  fi
}

check_no_obvious_secrets_in_bootstrap_script() {
  log_info "Checking bootstrap script for obvious embedded secrets..."

  if [[ ! -f "${BOOTSTRAP_SCRIPT}" ]]; then
    record_warn "Bootstrap script not found: ${BOOTSTRAP_SCRIPT}"
    return
  fi

  local secret_pattern
  secret_pattern='(OPENAI_API_KEY|ANTHROPIC_API_KEY|OPENROUTER_API_KEY|GROQ_API_KEY|TOGETHER_API_KEY|MISTRAL_API_KEY|GOOGLE_API_KEY|GEMINI_API_KEY|DEEPSEEK_API_KEY|api[_-]?key[[:space:]]*=|sk-[A-Za-z0-9_-]{20,})'

  if grep -Eiq "${secret_pattern}" "${BOOTSTRAP_SCRIPT}"; then
    record_error "Possible API key or secret found in ${BOOTSTRAP_SCRIPT}"
    record_error "Review the bootstrap script manually before committing or sharing it"
  else
    log_info "No obvious API keys found in ${BOOTSTRAP_SCRIPT}"
  fi
}

check_ripgrep() {
  log_info "Checking optional ripgrep dependency..."

  if run_in_ct "command -v rg >/dev/null 2>&1"; then
    log_info "ripgrep is installed"
  else
    record_warn "ripgrep is not installed. Hermes file search may use grep fallback"
    record_warn "Recommended: add ripgrep to scripts/step08c-hermes-bootstrap.sh package list"
  fi
}

print_summary() {
  echo
  log_info "======================================"
  log_info "STEP 08D - VALIDATION SUMMARY"
  log_info "======================================"

  if [[ "${VALIDATION_ERRORS}" -eq 0 ]]; then
    log_info "Validation completed with ${VALIDATION_ERRORS} errors and ${VALIDATION_WARNINGS} warnings"
    log_info "Hermes bootstrap validation passed"
    echo
    log_info "Hermes CT: ${HERMES_CT_ID}"
    log_info "Hostname: ${HERMES_CT_HOSTNAME}"
    log_info "Hermes CLI: ${HERMES_SYSTEM_BIN}"
    log_info "Hermes service: ${HERMES_SERVICE_NAME}"
    echo
    log_info "Next logical step:"
    log_info "  Step 08E - Hermes provider/model/API-key configuration"
    log_info "Handle API keys manually or via templates. Do not hard-code secrets into scripts."
  else
    log_error "Validation completed with ${VALIDATION_ERRORS} errors and ${VALIDATION_WARNINGS} warnings"
    log_error "Fix the errors above before continuing to Step 08E"
  fi
}

main() {
  log_info "======================================"
  log_info "STEP 08D - HERMES BOOTSTRAP VALIDATION"
  log_info "======================================"

  check_root_access
  check_required_host_commands

  if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
    log_error "Cannot continue because required host validation failed"
    print_summary
    exit 1
  fi

  check_ct_exists
  check_ct_running

  if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
    log_error "Cannot continue because CT validation failed"
    print_summary
    exit 1
  fi

  check_ct_identity
  check_hermes_cli
  check_hermes_directories
  check_systemd_service
  check_sudoers
  check_no_obvious_secrets_in_bootstrap_script
  check_ripgrep

  print_summary

  if [[ "${VALIDATION_ERRORS}" -eq 0 ]]; then
    exit 0
  fi

  exit 1
}

main "$@"
