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
HERMES_DASHBOARD_HOST="${HERMES_DASHBOARD_HOST:-0.0.0.0}"
HERMES_SYSTEM_BIN="${HERMES_SYSTEM_BIN:-/usr/local/bin/hermes}"
SERVICE_NAME="hermes-dashboard.service"
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "This script must be run as root on the Proxmox host."
    exit 1
  fi
}

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Required command not found: ${cmd}"
    exit 1
  fi
}

ct_must_exist_and_run() {
  if ! pct status "${HERMES_CT_ID}" >/dev/null 2>&1; then
    log_error "CT ${HERMES_CT_ID} does not exist."
    exit 1
  fi

  if ! pct status "${HERMES_CT_ID}" | grep -q "status: running"; then
    log_error "CT ${HERMES_CT_ID} is not running."
    exit 1
  fi
}

main() {
  log_info "======================================"
  log_info "STEP 09B - HERMES DASHBOARD SERVICE"
  log_info "======================================"

  require_root
  require_command pct
  ct_must_exist_and_run

  log_info "Installing ${SERVICE_NAME} inside CT ${HERMES_CT_ID}..."

  pct exec "${HERMES_CT_ID}" -- bash -s -- "${HERMES_DASHBOARD_HOST}" "${HERMES_DASHBOARD_PORT}" "${HERMES_SYSTEM_BIN}" << 'INNER'
set -Eeuo pipefail

DASHBOARD_HOST="$1"
DASHBOARD_PORT="$2"
HERMES_SYSTEM_BIN="$3"

if ! id hermes >/dev/null 2>&1; then
  echo "Hermes user does not exist." >&2
  exit 1
fi

if [[ ! -x "${HERMES_SYSTEM_BIN}" ]]; then
  echo "Hermes executable not found at ${HERMES_SYSTEM_BIN}" >&2
  exit 1
fi

cat > /etc/systemd/system/hermes-dashboard.service << UNIT
[Unit]
Description=Hermes Agent Dashboard - Web Admin Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hermes
Group=hermes
WorkingDirectory=/home/hermes/.hermes
Environment=HOME=/home/hermes
Environment=USER=hermes
Environment=LOGNAME=hermes
Environment=PATH=/home/hermes/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=HERMES_HOME=/home/hermes/.hermes
ExecStart=${HERMES_SYSTEM_BIN} dashboard --host ${DASHBOARD_HOST} --port ${DASHBOARD_PORT} --no-open --skip-build
Restart=always
RestartSec=5
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=90
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now hermes-dashboard.service
INNER

  log_info "Dashboard service installed and started."
  log_info "LAN URL: http://192.168.0.225:${HERMES_DASHBOARD_PORT}"
  log_warn "Do not expose this service directly to the internet."
}

main "$@"
