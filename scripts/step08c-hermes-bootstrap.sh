#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0
ENABLE_SERVICE=0
START_SERVICE=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --enable-service)
      ENABLE_SERVICE=1
      shift
      ;;
    --start-service)
      START_SERVICE=1
      ENABLE_SERVICE=1
      shift
      ;;
    -h|--help)
      cat <<'HELP'
Usage: step08c-hermes-bootstrap.sh [--dry-run] [--enable-service] [--start-service]

Installs Hermes Agent CLI inside CT 220 and prepares a systemd service.

Default behavior:
  - Install Hermes CLI as user hermes
  - Create /usr/local/bin/hermes symlink
  - Create /opt/hermes directories
  - Create hermes-gateway.service
  - Do not enable or start the service by default

Options:
  --enable-service   Enable hermes-gateway.service, but do not start it
  --start-service    Enable and start hermes-gateway.service
HELP
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

log_info "======================================"
log_info "STEP 08C - HERMES BOOTSTRAP"
log_info "======================================"

HERMES_CT_ID="${HERMES_CT_ID:-220}"
HERMES_CT_HOSTNAME="${HERMES_CT_HOSTNAME:-hermes-agent}"
HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="${HERMES_HOME:-/home/hermes}"
HERMES_BASE_DIR="${HERMES_BASE_DIR:-/opt/hermes}"
HERMES_INSTALL_URL="${HERMES_INSTALL_URL:-https://hermes-agent.nousresearch.com/install.sh}"
HERMES_LOCAL_BIN="${HERMES_HOME}/.local/bin/hermes"
HERMES_SYSTEM_BIN="${HERMES_SYSTEM_BIN:-/usr/local/bin/hermes}"
HERMES_SERVICE_NAME="${HERMES_SERVICE_NAME:-hermes-gateway.service}"
HERMES_SERVICE_PATH="/etc/systemd/system/${HERMES_SERVICE_NAME}"
HERMES_AGENT_HOME="${HERMES_AGENT_HOME:-${HERMES_HOME}/.hermes}"

run_host() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[DRY-RUN] $*"
  else
    "$@"
  fi
}

run_ct() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[DRY-RUN] pct exec ${HERMES_CT_ID} -- $*"
  else
    pct exec "${HERMES_CT_ID}" -- "$@"
  fi
}

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required host commands..."
for cmd in pct grep awk; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Required command not found on host: ${cmd}"
    exit 1
  fi
done

log_info "Checking whether CT ${HERMES_CT_ID} exists..."
if ! pct config "${HERMES_CT_ID}" >/dev/null 2>&1; then
  log_error "CT ${HERMES_CT_ID} does not exist. Run step08-hermes-lxc.sh first."
  exit 1
fi

log_info "Checking whether CT ${HERMES_CT_ID} is running..."
if ! pct status "${HERMES_CT_ID}" | grep -q "status: running"; then
  log_info "Starting CT ${HERMES_CT_ID}..."
  run_host pct start "${HERMES_CT_ID}"
fi

if [[ "${DRY_RUN}" -ne 1 ]]; then
  log_info "Waiting for CT ${HERMES_CT_ID} to become ready..."
  for _ in $(seq 1 30); do
    if pct exec "${HERMES_CT_ID}" -- true >/dev/null 2>&1; then
      log_info "CT ${HERMES_CT_ID} is ready"
      break
    fi
    sleep 2
  done
fi

log_info "Checking Hermes base user..."
if ! pct exec "${HERMES_CT_ID}" -- id "${HERMES_USER}" >/dev/null 2>&1; then
  log_error "User ${HERMES_USER} does not exist in CT ${HERMES_CT_ID}. Run step08-hermes-lxc.sh first."
  exit 1
fi

log_info "Checking DNS and HTTPS prerequisites..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] getent hosts hermes-agent.nousresearch.com"
else
  if ! pct exec "${HERMES_CT_ID}" -- getent hosts hermes-agent.nousresearch.com >/dev/null 2>&1; then
    log_error "DNS resolution failed inside CT ${HERMES_CT_ID}"
    exit 1
  fi
fi

log_info "Installing required base packages..."
run_ct apt-get update
run_ct apt-get install -y \
  ca-certificates \
  curl \
  git \
  jq \
  sudo \
  unzip \
  wget \
  ripgrep

log_info "Preparing Hermes directories..."
run_ct mkdir -p \
  "${HERMES_BASE_DIR}" \
  "${HERMES_BASE_DIR}/workspaces" \
  "${HERMES_BASE_DIR}/logs" \
  "${HERMES_HOME}/.config" \
  "${HERMES_HOME}/.local/bin" \
  "${HERMES_AGENT_HOME}"

run_ct chown -R "${HERMES_USER}:${HERMES_USER}" \
  "${HERMES_BASE_DIR}" \
  "${HERMES_HOME}/.config" \
  "${HERMES_HOME}/.local" \
  "${HERMES_AGENT_HOME}"

log_info "Installing Hermes Agent CLI as user ${HERMES_USER}..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] su - ${HERMES_USER} -c 'curl -fsSL ${HERMES_INSTALL_URL} | bash'"
else
  if pct exec "${HERMES_CT_ID}" -- test -x "${HERMES_LOCAL_BIN}"; then
    log_info "Hermes CLI already exists: ${HERMES_LOCAL_BIN}"
  else
    pct exec "${HERMES_CT_ID}" -- su - "${HERMES_USER}" -c "curl -fsSL '${HERMES_INSTALL_URL}' | bash"
  fi
fi

log_info "Creating system-wide Hermes symlink..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] ln -sfn ${HERMES_LOCAL_BIN} ${HERMES_SYSTEM_BIN}"
else
  if pct exec "${HERMES_CT_ID}" -- test -x "${HERMES_LOCAL_BIN}"; then
    pct exec "${HERMES_CT_ID}" -- ln -sfn "${HERMES_LOCAL_BIN}" "${HERMES_SYSTEM_BIN}"
  else
    log_error "Hermes CLI was not found after installation: ${HERMES_LOCAL_BIN}"
    exit 1
  fi
fi

log_info "Creating Hermes gateway systemd service..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] write ${HERMES_SERVICE_PATH}"
else
  pct exec "${HERMES_CT_ID}" -- bash -c "cat > '${HERMES_SERVICE_PATH}'" <<EOF
[Unit]
Description=Hermes Agent Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${HERMES_USER}
Group=${HERMES_USER}
WorkingDirectory=${HERMES_BASE_DIR}
Environment=HOME=${HERMES_HOME}
Environment=HERMES_HOME=${HERMES_AGENT_HOME}
Environment=PATH=${HERMES_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${HERMES_SYSTEM_BIN} gateway run
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
fi

log_info "Reloading systemd..."
run_ct systemctl daemon-reload

log_info "Updating Hermes sudoers helper..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] write /etc/sudoers.d/hermes-agent-base"
else
  pct exec "${HERMES_CT_ID}" -- bash -c "cat > /etc/sudoers.d/hermes-agent-base" <<EOF
${HERMES_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl status ${HERMES_SERVICE_NAME}, /usr/bin/journalctl -u ${HERMES_SERVICE_NAME}
EOF
  pct exec "${HERMES_CT_ID}" -- chmod 0440 /etc/sudoers.d/hermes-agent-base
  pct exec "${HERMES_CT_ID}" -- visudo -cf /etc/sudoers.d/hermes-agent-base >/dev/null
fi

if [[ "${ENABLE_SERVICE}" -eq 1 ]]; then
  log_info "Enabling ${HERMES_SERVICE_NAME}..."
  run_ct systemctl enable "${HERMES_SERVICE_NAME}"
else
  log_info "Service enablement skipped. Use --enable-service when ready."
fi

if [[ "${START_SERVICE}" -eq 1 ]]; then
  log_info "Starting ${HERMES_SERVICE_NAME}..."
  run_ct systemctl restart "${HERMES_SERVICE_NAME}"
else
  log_info "Service start skipped. Use --start-service when Hermes config/API keys are ready."
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "Dry-run completed successfully"
  log_info "No changes were made because --dry-run was used"
  exit 0
fi

log_info "Validating Hermes CLI..."
if pct exec "${HERMES_CT_ID}" -- bash -c "test -x '${HERMES_LOCAL_BIN}'"; then
  log_info "Hermes CLI exists: ${HERMES_LOCAL_BIN}"
else
  log_error "Hermes CLI missing: ${HERMES_LOCAL_BIN}"
  exit 1
fi

if pct exec "${HERMES_CT_ID}" -- bash -c "PATH=/usr/local/bin:/usr/bin:/bin command -v hermes >/dev/null 2>&1"; then
  log_info "Hermes is available in controlled PATH"
else
  log_error "Hermes is not available in controlled PATH"
  exit 1
fi

if pct exec "${HERMES_CT_ID}" -- bash -c "PATH=/usr/local/bin:/usr/bin:/bin hermes --help >/dev/null 2>&1"; then
  log_info "Hermes CLI responds to --help"
else
  log_error "Hermes CLI did not respond to --help"
  exit 1
fi

log_info "Validating systemd service file..."
if pct exec "${HERMES_CT_ID}" -- systemctl cat "${HERMES_SERVICE_NAME}" >/dev/null 2>&1; then
  log_info "Systemd service exists: ${HERMES_SERVICE_NAME}"
else
  log_error "Systemd service missing: ${HERMES_SERVICE_NAME}"
  exit 1
fi

if [[ "${ENABLE_SERVICE}" -eq 1 ]]; then
  if pct exec "${HERMES_CT_ID}" -- systemctl is-enabled --quiet "${HERMES_SERVICE_NAME}"; then
    log_info "Systemd service is enabled"
  else
    log_error "Systemd service was expected to be enabled but is not"
    exit 1
  fi
fi

if [[ "${START_SERVICE}" -eq 1 ]]; then
  if pct exec "${HERMES_CT_ID}" -- systemctl is-active --quiet "${HERMES_SERVICE_NAME}"; then
    log_info "Systemd service is active"
  else
    log_error "Systemd service was expected to be active but is not"
    log_error "Check logs with: pct exec ${HERMES_CT_ID} -- journalctl -u ${HERMES_SERVICE_NAME} --no-pager -n 80"
    exit 1
  fi
fi

HERMES_CT_IP="$(
  pct exec "${HERMES_CT_ID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true
)"

log_info "Hermes bootstrap completed successfully"
log_info "CT ID: ${HERMES_CT_ID}"
log_info "Hostname: ${HERMES_CT_HOSTNAME}"

if [[ -n "${HERMES_CT_IP}" ]]; then
  log_info "Hermes CT IP: ${HERMES_CT_IP}"
fi

log_info "Hermes CLI: ${HERMES_SYSTEM_BIN}"
log_info "Hermes service: ${HERMES_SERVICE_NAME}"
log_info "Service was not started unless --start-service was used"
log_info "Next step should configure Hermes provider/API keys outside this script."
