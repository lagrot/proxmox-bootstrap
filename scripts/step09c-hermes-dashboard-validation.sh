#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/logging.sh"
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/lib/common.sh"

if [[ -f "${PROJECT_ROOT}/config/defaults.conf" ]]; then
  # shellcheck disable=SC1091
  source "${PROJECT_ROOT}/config/defaults.conf"
fi

HERMES_CT_ID="${HERMES_CT_ID:-220}"
HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
SERVICE_NAME="hermes-dashboard.service"

VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0
record_warning() {
  log_warn "$1"
  VALIDATION_WARNINGS=$((VALIDATION_WARNINGS + 1))
}

record_error() {
  log_error "$1"
  VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
}

check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    record_error "This script must be run as root on the Proxmox host."
  fi
}

check_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    record_error "Required command not found: ${cmd}"
  fi
}

check_ct() {
  if ! pct status "${HERMES_CT_ID}" >/dev/null 2>&1; then
    record_error "CT ${HERMES_CT_ID} does not exist."
    return
  fi

  if pct status "${HERMES_CT_ID}" | grep -q "status: running"; then
    log_info "CT ${HERMES_CT_ID} is running."
  else
    record_error "CT ${HERMES_CT_ID} is not running."
  fi
}

check_service() {
  if pct exec "${HERMES_CT_ID}" -- systemctl is-enabled "${SERVICE_NAME}" >/dev/null 2>&1; then
    log_info "${SERVICE_NAME} is enabled."
  else
    record_error "${SERVICE_NAME} is not enabled."
  fi

  if pct exec "${HERMES_CT_ID}" -- systemctl is-active "${SERVICE_NAME}" >/dev/null 2>&1; then
    log_info "${SERVICE_NAME} is active."
  else
    record_error "${SERVICE_NAME} is not active."
  fi
}

check_port() {
  if pct exec "${HERMES_CT_ID}" -- bash -c "ss -ltn | grep -q ':${HERMES_DASHBOARD_PORT} '" >/dev/null 2>&1; then
    log_info "Dashboard port ${HERMES_DASHBOARD_PORT} is listening."
  else
    record_error "Dashboard port ${HERMES_DASHBOARD_PORT} is not listening."
  fi
}

check_http() {
  local http_code

  http_code="$(
    pct exec "${HERMES_CT_ID}" -- bash -c \
      "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:${HERMES_DASHBOARD_PORT}/" \
      2>/dev/null || true
  )"

  case "${http_code}" in
    200|302|401)
      log_info "Dashboard HTTP check returned ${http_code}, which is acceptable."
      ;;
    *)
      record_error "Dashboard HTTP check returned unexpected code: ${http_code:-none}"
      ;;
  esac
}

check_logs() {
  if pct exec "${HERMES_CT_ID}" -- journalctl -u "${SERVICE_NAME}" -n 80 --no-pager | grep -Ei "traceback|permission denied|address already in use|failed" >/dev/null 2>&1; then
    record_warning "Possible warning/error text found in recent dashboard logs. Review with:"
    record_warning "pct exec ${HERMES_CT_ID} -- journalctl -u ${SERVICE_NAME} -n 80 --no-pager"
  else
    log_info "No obvious recent dashboard service errors found."
  fi
}

main() {
  log_info "=========================================="
  log_info "STEP 09C - HERMES DASHBOARD VALIDATION"
  log_info "=========================================="

  check_root
  check_command pct

  if [[ "${VALIDATION_ERRORS}" -eq 0 ]]; then
    check_ct
  fi

  if [[ "${VALIDATION_ERRORS}" -eq 0 ]]; then
    check_service
    check_port
    check_http
    check_logs
  fi

  echo
  log_info "Validation warnings: ${VALIDATION_WARNINGS}"
  log_info "Validation errors: ${VALIDATION_ERRORS}"

  if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
    log_error "Hermes dashboard validation failed."
    exit 1
  fi

  log_info "Hermes dashboard validation passed."
}

main "$@"
