#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      cat <<'HELP'
Usage: step08-hermes-lxc.sh [--dry-run]

Creates isolated Hermes Agent LXC container.

Default CT:
  ID:        220
  Hostname:  hermes-agent
  Template:  Debian 13
  Storage:   local-lvm
  Network:   DHCP on vmbr0

This step creates and prepares the base LXC only.
It does not install Hermes itself.
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
log_info "STEP 08 - HERMES AGENT LXC"
log_info "======================================"

HERMES_CT_ID="${HERMES_CT_ID:-220}"
HERMES_CT_HOSTNAME="${HERMES_CT_HOSTNAME:-hermes-agent}"
HERMES_CT_TEMPLATE_STORAGE="${HERMES_CT_TEMPLATE_STORAGE:-local}"
HERMES_CT_STORAGE="${HERMES_CT_STORAGE:-local-lvm}"
HERMES_CT_TEMPLATE_FILE="${HERMES_CT_TEMPLATE_FILE:-debian-13-standard_13.1-2_amd64.tar.zst}"
HERMES_CT_ROOTFS_SIZE="${HERMES_CT_ROOTFS_SIZE:-16}"
HERMES_CT_MEMORY_MB="${HERMES_CT_MEMORY_MB:-2048}"
HERMES_CT_SWAP_MB="${HERMES_CT_SWAP_MB:-512}"
HERMES_CT_CORES="${HERMES_CT_CORES:-2}"
HERMES_CT_BRIDGE="${HERMES_CT_BRIDGE:-vmbr0}"
HERMES_CT_IP_CONFIG="${HERMES_CT_IP_CONFIG:-dhcp}"
HERMES_CT_UNPRIVILEGED="${HERMES_CT_UNPRIVILEGED:-1}"
HERMES_CT_ONBOOT="${HERMES_CT_ONBOOT:-1}"
HERMES_CT_FEATURES="${HERMES_CT_FEATURES:-nesting=1,keyctl=1}"

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="${HERMES_HOME:-/home/hermes}"
HERMES_BASE_DIR="${HERMES_BASE_DIR:-/opt/hermes}"

TEMPLATE_REF="${HERMES_CT_TEMPLATE_STORAGE}:vztmpl/${HERMES_CT_TEMPLATE_FILE}"

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

wait_for_ct_ready() {
  local attempts=30
  local sleep_seconds=2

  log_info "Waiting for CT ${HERMES_CT_ID} to become ready..."

  for _ in $(seq 1 "${attempts}"); do
    if pct exec "${HERMES_CT_ID}" -- true >/dev/null 2>&1; then
      log_info "CT ${HERMES_CT_ID} is ready"
      return 0
    fi
    sleep "${sleep_seconds}"
  done

  log_error "CT ${HERMES_CT_ID} did not become ready in time"
  return 1
}

wait_for_network() {
  local attempts=30
  local sleep_seconds=2

  log_info "Waiting for network inside CT ${HERMES_CT_ID}..."

  for _ in $(seq 1 "${attempts}"); do
    if pct exec "${HERMES_CT_ID}" -- ip -4 addr show eth0 2>/dev/null | grep -q "inet "; then
      log_info "IPv4 address detected on eth0"
      return 0
    fi
    sleep "${sleep_seconds}"
  done

  log_error "No IPv4 address detected on eth0 in CT ${HERMES_CT_ID}"
  return 1
}

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required host commands..."
for cmd in pct pvesm awk grep ip; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Required command not found: ${cmd}"
    exit 1
  fi
done

log_info "Checking Proxmox bridge ${HERMES_CT_BRIDGE}..."
if ! ip link show "${HERMES_CT_BRIDGE}" >/dev/null 2>&1; then
  log_error "Proxmox bridge not found: ${HERMES_CT_BRIDGE}"
  exit 1
fi

log_info "Checking container storage ${HERMES_CT_STORAGE}..."
if ! pvesm status | awk '{print $1}' | grep -qx "${HERMES_CT_STORAGE}"; then
  log_error "Container storage not found: ${HERMES_CT_STORAGE}"
  exit 1
fi

log_info "Checking template storage ${HERMES_CT_TEMPLATE_STORAGE}..."
if ! pvesm status | awk '{print $1}' | grep -qx "${HERMES_CT_TEMPLATE_STORAGE}"; then
  log_error "Template storage not found: ${HERMES_CT_TEMPLATE_STORAGE}"
  exit 1
fi

log_info "Checking template ${TEMPLATE_REF}..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] check template exists: ${TEMPLATE_REF}"
else
  if [[ ! -f "/var/lib/vz/template/cache/${HERMES_CT_TEMPLATE_FILE}" ]]; then
    log_error "Template not found: /var/lib/vz/template/cache/${HERMES_CT_TEMPLATE_FILE}"
    log_error "Download it first from Proxmox UI or with pveam."
    exit 1
  fi
fi

log_info "Checking whether CT ${HERMES_CT_ID} already exists..."
if pct config "${HERMES_CT_ID}" >/dev/null 2>&1; then
  log_info "CT ${HERMES_CT_ID} already exists"
else
  log_info "Creating CT ${HERMES_CT_ID} (${HERMES_CT_HOSTNAME})..."

  run_host pct create "${HERMES_CT_ID}" "${TEMPLATE_REF}" \
    --hostname "${HERMES_CT_HOSTNAME}" \
    --storage "${HERMES_CT_STORAGE}" \
    --rootfs "${HERMES_CT_STORAGE}:${HERMES_CT_ROOTFS_SIZE}" \
    --memory "${HERMES_CT_MEMORY_MB}" \
    --swap "${HERMES_CT_SWAP_MB}" \
    --cores "${HERMES_CT_CORES}" \
    --net0 "name=eth0,bridge=${HERMES_CT_BRIDGE},ip=${HERMES_CT_IP_CONFIG},type=veth" \
    --unprivileged "${HERMES_CT_UNPRIVILEGED}" \
    --onboot "${HERMES_CT_ONBOOT}" \
    --features "${HERMES_CT_FEATURES}"
fi

log_info "Ensuring CT ${HERMES_CT_ID} is started..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] pct status ${HERMES_CT_ID}"
  log_info "[DRY-RUN] pct start ${HERMES_CT_ID} if not running"
  log_info "Dry-run completed successfully"
  log_info "No CT was created or modified because --dry-run was used"
  exit 0
fi

if ! pct status "${HERMES_CT_ID}" | grep -q "status: running"; then
  run_host pct start "${HERMES_CT_ID}"
fi

wait_for_ct_ready
wait_for_network

log_info "Checking DNS inside CT ${HERMES_CT_ID}..."
if pct exec "${HERMES_CT_ID}" -- getent hosts deb.debian.org >/dev/null 2>&1; then
  log_info "DNS resolution works"
else
  log_error "DNS resolution failed inside CT ${HERMES_CT_ID}"
  exit 1
fi

log_info "Installing base packages inside CT ${HERMES_CT_ID}..."
run_ct apt-get update
run_ct apt-get install -y \
  ca-certificates \
  curl \
  git \
  jq \
  nano \
  python3 \
  python3-pip \
  python3-venv \
  sudo \
  unzip \
  vim \
  wget

log_info "Creating Hermes user and directories..."
if pct exec "${HERMES_CT_ID}" -- id "${HERMES_USER}" >/dev/null 2>&1; then
  log_info "User ${HERMES_USER} already exists"
else
  run_ct useradd -m -s /bin/bash "${HERMES_USER}"
fi

run_ct mkdir -p "${HERMES_BASE_DIR}"
run_ct chown -R "${HERMES_USER}:${HERMES_USER}" "${HERMES_BASE_DIR}"
run_ct mkdir -p "${HERMES_HOME}/.config" "${HERMES_HOME}/.local/bin"
run_ct chown -R "${HERMES_USER}:${HERMES_USER}" "${HERMES_HOME}"

log_info "Configuring limited sudo placeholder for Hermes user..."
run_ct bash -c "cat > /etc/sudoers.d/hermes-agent-base" <<EOF
${HERMES_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl status hermes-gateway, /usr/bin/journalctl -u hermes-gateway
EOF
run_ct chmod 0440 /etc/sudoers.d/hermes-agent-base

log_info "Validating CT ${HERMES_CT_ID}..."
if pct status "${HERMES_CT_ID}" | grep -q "status: running"; then
  log_info "CT ${HERMES_CT_ID} is running"
else
  log_error "CT ${HERMES_CT_ID} is not running"
  exit 1
fi

if pct exec "${HERMES_CT_ID}" -- id "${HERMES_USER}" >/dev/null 2>&1; then
  log_info "Hermes user exists: ${HERMES_USER}"
else
  log_error "Hermes user does not exist: ${HERMES_USER}"
  exit 1
fi

if pct exec "${HERMES_CT_ID}" -- test -d "${HERMES_BASE_DIR}"; then
  log_info "Hermes base directory exists: ${HERMES_BASE_DIR}"
else
  log_error "Hermes base directory missing: ${HERMES_BASE_DIR}"
  exit 1
fi

if pct exec "${HERMES_CT_ID}" -- bash -c 'command -v python3 >/dev/null 2>&1'; then
  log_info "Python is installed"
else
  log_error "Python is missing"
  exit 1
fi

HERMES_CT_IP="$(
  pct exec "${HERMES_CT_ID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true
)"

log_info "Hermes LXC base deployment completed successfully"
log_info "CT ID: ${HERMES_CT_ID}"
log_info "Hostname: ${HERMES_CT_HOSTNAME}"

if [[ -n "${HERMES_CT_IP}" ]]; then
  log_info "Hermes CT IP: ${HERMES_CT_IP}"
fi

log_info "Next step should install/configure Hermes itself in a separate script."
