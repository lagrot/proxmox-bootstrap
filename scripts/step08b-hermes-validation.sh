#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

log_info "======================================"
log_info "STEP 08B - HERMES LXC VALIDATION"
log_info "======================================"

HERMES_CT_ID="${HERMES_CT_ID:-220}"
HERMES_CT_HOSTNAME="${HERMES_CT_HOSTNAME:-hermes-agent}"
HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="${HERMES_HOME:-/home/hermes}"
HERMES_BASE_DIR="${HERMES_BASE_DIR:-/opt/hermes}"

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

check_ct_command() {
  local cmd="$1"

  if pct exec "${HERMES_CT_ID}" -- bash -c "command -v '${cmd}' >/dev/null 2>&1"; then
    log_info "CT command found: ${cmd}"
  else
    record_error "Required command not found inside CT ${HERMES_CT_ID}: ${cmd}"
  fi
}

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required host commands..."
for cmd in pct grep awk; do
  check_host_command "${cmd}"
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Missing required host commands"
  exit 1
fi

log_info "Checking whether CT ${HERMES_CT_ID} exists..."
if pct config "${HERMES_CT_ID}" >/dev/null 2>&1; then
  log_info "CT ${HERMES_CT_ID} exists"
else
  record_error "CT ${HERMES_CT_ID} does not exist"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Cannot continue because CT ${HERMES_CT_ID} is missing"
  exit 1
fi

CT_CONFIG="$(pct config "${HERMES_CT_ID}")"

log_info "Checking whether CT ${HERMES_CT_ID} is running..."
if pct status "${HERMES_CT_ID}" | grep -q "status: running"; then
  log_info "CT ${HERMES_CT_ID} is running"
else
  record_error "CT ${HERMES_CT_ID} is not running"
fi

log_info "Checking CT hostname..."
CT_HOSTNAME="$(pct exec "${HERMES_CT_ID}" -- hostname 2>/dev/null || true)"

if [[ "${CT_HOSTNAME}" == "${HERMES_CT_HOSTNAME}" ]]; then
  log_info "CT hostname is ${HERMES_CT_HOSTNAME}"
else
  record_warn "CT hostname is '${CT_HOSTNAME}', expected '${HERMES_CT_HOSTNAME}'"
fi

log_info "Checking CT config basics..."
if grep -q "^hostname: ${HERMES_CT_HOSTNAME}$" <<< "${CT_CONFIG}"; then
  log_info "LXC config hostname is ${HERMES_CT_HOSTNAME}"
else
  record_warn "LXC config hostname does not match ${HERMES_CT_HOSTNAME}"
fi

if grep -q "^onboot: 1$" <<< "${CT_CONFIG}"; then
  log_info "CT is configured to start on boot"
else
  record_warn "CT is not configured to start on boot"
fi

if grep -q "^unprivileged: 1$" <<< "${CT_CONFIG}"; then
  log_info "CT is unprivileged"
else
  record_warn "CT is not unprivileged"
fi

if grep -q "^features: .*nesting=1" <<< "${CT_CONFIG}"; then
  log_info "CT nesting feature is enabled"
else
  record_warn "CT nesting feature is not enabled"
fi

if grep -q "^features: .*keyctl=1" <<< "${CT_CONFIG}"; then
  log_info "CT keyctl feature is enabled"
else
  record_warn "CT keyctl feature is not enabled"
fi

log_info "Checking network inside CT ${HERMES_CT_ID}..."
HERMES_CT_IP="$(
  pct exec "${HERMES_CT_ID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true
)"

if [[ -n "${HERMES_CT_IP}" ]]; then
  log_info "Hermes CT IP: ${HERMES_CT_IP}"
else
  record_error "Could not detect Hermes CT IP"
fi

if pct exec "${HERMES_CT_ID}" -- ip route | grep -q "^default "; then
  log_info "Default route exists"
else
  record_error "Default route missing inside CT ${HERMES_CT_ID}"
fi

log_info "Checking DNS inside CT ${HERMES_CT_ID}..."
if pct exec "${HERMES_CT_ID}" -- getent hosts deb.debian.org >/dev/null 2>&1; then
  log_info "DNS resolution works"
else
  record_error "DNS resolution failed inside CT ${HERMES_CT_ID}"
fi

log_info "Checking useful commands inside CT ${HERMES_CT_ID}..."
for cmd in bash curl git jq python3 pip3 sudo vim wget; do
  check_ct_command "${cmd}"
done

log_info "Checking Python version..."
PYTHON_VERSION="$(pct exec "${HERMES_CT_ID}" -- python3 --version 2>/dev/null || true)"
if [[ -n "${PYTHON_VERSION}" ]]; then
  log_info "${PYTHON_VERSION}"
else
  record_error "Could not get Python version"
fi

log_info "Checking pip version..."
PIP_VERSION="$(pct exec "${HERMES_CT_ID}" -- pip3 --version 2>/dev/null || true)"
if [[ -n "${PIP_VERSION}" ]]; then
  log_info "${PIP_VERSION}"
else
  record_warn "Could not get pip version"
fi

log_info "Checking venv module..."
if pct exec "${HERMES_CT_ID}" -- python3 -m venv --help >/dev/null 2>&1; then
  log_info "Python venv module works"
else
  record_error "Python venv module does not work"
fi

log_info "Checking Hermes user..."
if pct exec "${HERMES_CT_ID}" -- id "${HERMES_USER}" >/dev/null 2>&1; then
  log_info "Hermes user exists: ${HERMES_USER}"
else
  record_error "Hermes user does not exist: ${HERMES_USER}"
fi

log_info "Checking Hermes home directory..."
if pct exec "${HERMES_CT_ID}" -- test -d "${HERMES_HOME}"; then
  log_info "Hermes home directory exists: ${HERMES_HOME}"
else
  record_error "Hermes home directory missing: ${HERMES_HOME}"
fi

log_info "Checking Hermes base directory..."
if pct exec "${HERMES_CT_ID}" -- test -d "${HERMES_BASE_DIR}"; then
  log_info "Hermes base directory exists: ${HERMES_BASE_DIR}"
else
  record_error "Hermes base directory missing: ${HERMES_BASE_DIR}"
fi

log_info "Checking Hermes directory ownership..."
BASE_OWNER="$(
  pct exec "${HERMES_CT_ID}" -- stat -c '%U:%G' "${HERMES_BASE_DIR}" 2>/dev/null || true
)"

if [[ "${BASE_OWNER}" == "${HERMES_USER}:${HERMES_USER}" ]]; then
  log_info "${HERMES_BASE_DIR} owner is ${HERMES_USER}:${HERMES_USER}"
else
  record_warn "${HERMES_BASE_DIR} owner is '${BASE_OWNER}', expected '${HERMES_USER}:${HERMES_USER}'"
fi

HOME_OWNER="$(
  pct exec "${HERMES_CT_ID}" -- stat -c '%U:%G' "${HERMES_HOME}" 2>/dev/null || true
)"

if [[ "${HOME_OWNER}" == "${HERMES_USER}:${HERMES_USER}" ]]; then
  log_info "${HERMES_HOME} owner is ${HERMES_USER}:${HERMES_USER}"
else
  record_warn "${HERMES_HOME} owner is '${HOME_OWNER}', expected '${HERMES_USER}:${HERMES_USER}'"
fi

log_info "Checking Hermes config directories..."
for dir in "${HERMES_HOME}/.config" "${HERMES_HOME}/.local/bin"; do
  if pct exec "${HERMES_CT_ID}" -- test -d "${dir}"; then
    log_info "Directory exists: ${dir}"
  else
    record_warn "Directory missing: ${dir}"
  fi
done

log_info "Checking sudoers placeholder..."
if pct exec "${HERMES_CT_ID}" -- test -f /etc/sudoers.d/hermes-agent-base; then
  log_info "Sudoers placeholder exists: /etc/sudoers.d/hermes-agent-base"
else
  record_warn "Sudoers placeholder missing: /etc/sudoers.d/hermes-agent-base"
fi

if pct exec "${HERMES_CT_ID}" -- bash -c 'visudo -cf /etc/sudoers.d/hermes-agent-base >/dev/null 2>&1'; then
  log_info "Sudoers placeholder syntax is valid"
else
  record_warn "Could not validate sudoers placeholder syntax"
fi

log_info "Checking whether Hermes service already exists..."
if pct exec "${HERMES_CT_ID}" -- systemctl list-unit-files hermes-gateway.service --no-pager 2>/dev/null | grep -q "hermes-gateway.service"; then
  record_warn "hermes-gateway.service already exists; Step 08 is supposed to be base LXC only"
else
  log_info "hermes-gateway.service is not installed yet, as expected"
fi

log_info "======================================"
log_info "HERMES LXC VALIDATION SUMMARY"
log_info "======================================"
log_info "Validation warnings: ${VALIDATION_WARNINGS}"
log_info "Validation errors: ${VALIDATION_ERRORS}"

if [[ -n "${HERMES_CT_IP}" ]]; then
  log_info "Hermes CT IP: ${HERMES_CT_IP}"
fi

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
  log_error "Hermes LXC validation failed"
  exit 1
fi

if [[ "${VALIDATION_WARNINGS}" -gt 0 ]]; then
  log_warn "Hermes LXC validation completed with warnings"
  exit 0
fi

log_info "Hermes LXC validation completed successfully"
