#!/usr/bin/env bash
set -euo pipefail

# ======================================
# STEP 08F - HERMES GATEWAY VALIDATION
# ======================================
#
# Read-only validation for the running Hermes gateway service in CT 220.
#
# This validates the state after:
#   Step 08E - Hermes provider/model/API-key configuration
#   systemctl enable/start hermes-gateway.service
#
# It does not install, modify, enable, start, stop, or restart anything.
#
# Validates:
#   - CT 220 exists and is running
#   - Hermes CLI exists and works
#   - Hermes config and secrets files exist
#   - Hermes provider smoke test works
#   - hermes-gateway.service exists
#   - service is enabled
#   - service is active
#   - recent logs have no obvious fatal/startup errors
#
# Expected warnings for now:
#   - No messaging platforms enabled
#   - No env user allowlists configured
#
# These are acceptable until Telegram/Discord/WhatsApp/etc. are configured.

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
HERMES_CONFIG_FILE="${HERMES_HOME}/.hermes/config.yaml"
HERMES_SECRETS_FILE="${HERMES_HOME}/.hermes/.env"
HERMES_SERVICE_NAME="hermes-gateway.service"
HERMES_SERVICE_PATH="/etc/systemd/system/${HERMES_SERVICE_NAME}"

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

run_as_hermes() {
  pct exec "${HERMES_CT_ID}" -- runuser -l "${HERMES_USER}" -c "$1"
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
  for cmd in pct grep awk; do
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
    log_info "Hermes system symlink exists: ${HERMES_SYSTEM_BIN}"
  else
    record_error "Hermes system symlink missing: ${HERMES_SYSTEM_BIN}"
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

check_hermes_config_files() {
  log_info "Checking Hermes config and secrets files..."

  if run_in_ct "test -f '${HERMES_CONFIG_FILE}'"; then
    log_info "Hermes config exists: ${HERMES_CONFIG_FILE}"
  else
    record_error "Hermes config missing: ${HERMES_CONFIG_FILE}"
  fi

  if run_in_ct "test -f '${HERMES_SECRETS_FILE}'"; then
    log_info "Hermes secrets file exists: ${HERMES_SECRETS_FILE}"
  else
    record_error "Hermes secrets file missing: ${HERMES_SECRETS_FILE}"
  fi

  if run_in_ct "grep -q '^OPENROUTER_API_KEY=' '${HERMES_SECRETS_FILE}'"; then
    log_info "OpenRouter API key variable exists in Hermes secrets file"
  else
    record_warn "OPENROUTER_API_KEY was not found in ${HERMES_SECRETS_FILE}"
  fi

  if run_in_ct "grep -q 'provider.*openrouter\\|provider: openrouter' '${HERMES_CONFIG_FILE}'"; then
    log_info "Hermes config appears to use OpenRouter provider"
  else
    record_warn "Could not confirm OpenRouter provider from ${HERMES_CONFIG_FILE}"
  fi
}

check_hermes_provider_smoke_test() {
  log_info "Running Hermes provider smoke test..."

  local output
  output="$(
    run_as_hermes 'PATH=/usr/local/bin:/usr/bin:/bin hermes -z "Reply with exactly: Hermes provider test OK"' 2>/dev/null || true
  )"

  if echo "${output}" | grep -q '^Hermes provider test OK$'; then
    log_info "Hermes provider smoke test passed"
  else
    record_error "Hermes provider smoke test failed"
    log_error "Smoke test output was:"
    echo "${output}"
  fi
}

check_systemd_service_file() {
  log_info "Checking Hermes gateway systemd service file..."

  if run_in_ct "test -f '${HERMES_SERVICE_PATH}'"; then
    log_info "Service file exists: ${HERMES_SERVICE_PATH}"
  else
    record_error "Service file missing: ${HERMES_SERVICE_PATH}"
  fi

  if run_in_ct "grep -q '^User=${HERMES_USER}$' '${HERMES_SERVICE_PATH}'"; then
    log_info "Service runs as user ${HERMES_USER}"
  else
    record_warn "Could not confirm service user ${HERMES_USER}"
  fi

  if run_in_ct "grep -q '^ExecStart=${HERMES_SYSTEM_BIN} gateway run$' '${HERMES_SERVICE_PATH}'"; then
    log_info "Service ExecStart is correct"
  else
    record_warn "Could not confirm expected ExecStart in ${HERMES_SERVICE_PATH}"
  fi

  if run_in_ct "systemctl list-unit-files '${HERMES_SERVICE_NAME}' >/dev/null 2>&1"; then
    log_info "systemd knows about ${HERMES_SERVICE_NAME}"
  else
    record_error "systemd does not know about ${HERMES_SERVICE_NAME}"
  fi
}

check_gateway_service_state() {
  log_info "Checking Hermes gateway service state..."

  local enabled_state
  enabled_state="$(run_in_ct "systemctl is-enabled '${HERMES_SERVICE_NAME}' 2>/dev/null" || true)"

  if [[ "${enabled_state}" == "enabled" ]]; then
    log_info "${HERMES_SERVICE_NAME} is enabled"
  else
    record_error "${HERMES_SERVICE_NAME} is not enabled. Current state: ${enabled_state:-unknown}"
  fi

  local active_state
  active_state="$(run_in_ct "systemctl is-active '${HERMES_SERVICE_NAME}' 2>/dev/null" || true)"

  if [[ "${active_state}" == "active" ]]; then
    log_info "${HERMES_SERVICE_NAME} is active"
  else
    record_error "${HERMES_SERVICE_NAME} is not active. Current state: ${active_state:-unknown}"
  fi
}

check_gateway_status_command() {
  log_info "Checking Hermes gateway status command..."

  if run_as_hermes 'PATH=/usr/local/bin:/usr/bin:/bin hermes gateway status >/dev/null 2>&1'; then
    log_info "hermes gateway status works"
  else
    record_warn "hermes gateway status returned non-zero"
    record_warn "This may be acceptable if no messaging platforms are configured yet"
  fi
}

check_recent_gateway_logs() {
  log_info "Checking recent Hermes gateway logs..."

  local logs
  logs="$(run_in_ct "journalctl -u '${HERMES_SERVICE_NAME}' --no-pager -n 120 2>/dev/null" || true)"

  if [[ -z "${logs}" ]]; then
    record_warn "No recent logs found for ${HERMES_SERVICE_NAME}"
    return
  fi

  if echo "${logs}" | grep -Eiq 'traceback|exception|critical|fatal|failed|error'; then
    record_error "Recent Hermes gateway logs contain possible fatal/error messages"
    log_error "Review with:"
    log_error "  pct exec ${HERMES_CT_ID} -- journalctl -u ${HERMES_SERVICE_NAME} --no-pager -n 120"
  else
    log_info "No obvious fatal/error messages found in recent gateway logs"
  fi

  if echo "${logs}" | grep -q 'No messaging platforms enabled'; then
    record_warn "No messaging platforms enabled yet. This is expected before Telegram/Discord/WhatsApp setup"
  fi

  if echo "${logs}" | grep -q 'No env user allowlists configured'; then
    record_warn "No gateway user allowlists configured yet. This is expected before messaging platform setup"
  fi
}

check_hermes_doctor_core() {
  log_info "Checking Hermes doctor core status..."

  local doctor_output
  doctor_output="$(run_as_hermes 'PATH=/usr/local/bin:/usr/bin:/bin hermes doctor' 2>/dev/null || true)"

  if echo "${doctor_output}" | grep -q 'OpenRouter API'; then
    log_info "Hermes doctor reports OpenRouter API section"
  else
    record_warn "Hermes doctor output did not clearly show OpenRouter API"
  fi

  if echo "${doctor_output}" | grep -q '✓ OpenRouter API'; then
    log_info "Hermes doctor confirms OpenRouter API connectivity"
  else
    record_warn "Hermes doctor did not confirm OpenRouter API connectivity"
  fi
}

print_summary() {
  echo
  log_info "======================================"
  log_info "STEP 08F - VALIDATION SUMMARY"
  log_info "======================================"

  if [[ "${VALIDATION_ERRORS}" -eq 0 ]]; then
    log_info "Validation completed with ${VALIDATION_ERRORS} errors and ${VALIDATION_WARNINGS} warnings"
    log_info "Hermes gateway validation passed"
    echo
    log_info "Hermes CT: ${HERMES_CT_ID}"
    log_info "Hostname: ${HERMES_CT_HOSTNAME}"
    log_info "Hermes CLI: ${HERMES_SYSTEM_BIN}"
    log_info "Hermes service: ${HERMES_SERVICE_NAME}"
    log_info "Service state: enabled + active"
    echo
    log_info "Expected current warnings:"
    log_info "  No messaging platforms enabled"
    log_info "  No gateway user allowlists configured"
    echo
    log_info "Next logical step:"
    log_info "  Step 09 - Configure a messaging platform or integration"
    log_info "Recommended first platform later: Telegram, Discord, Slack, or Home Assistant"
  else
    log_error "Validation completed with ${VALIDATION_ERRORS} errors and ${VALIDATION_WARNINGS} warnings"
    log_error "Fix the errors above before continuing"
  fi
}

main() {
  log_info "======================================"
  log_info "STEP 08F - HERMES GATEWAY VALIDATION"
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
  check_hermes_config_files
  check_hermes_provider_smoke_test
  check_systemd_service_file
  check_gateway_service_state
  check_gateway_status_command
  check_recent_gateway_logs
  check_hermes_doctor_core

  print_summary

  if [[ "${VALIDATION_ERRORS}" -eq 0 ]]; then
    exit 0
  fi

  exit 1
}

main "$@"
