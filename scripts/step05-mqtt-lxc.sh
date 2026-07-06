#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

log_info "======================================"
log_info "STEP 05 - MQTT LXC DEPLOYMENT"
log_info "======================================"

DRY_RUN=0

for arg in "$@"; do
  case "${arg}" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--dry-run]

Create and bootstrap CT 210 mqtt-core with native Mosquitto.
EOF
      exit 0
      ;;
    *)
      log_error "Unknown argument: ${arg}"
      exit 1
      ;;
  esac
done

MQTT_CT_ID="${MQTT_CT_ID:-210}"
MQTT_CT_HOSTNAME="${MQTT_CT_HOSTNAME:-mqtt-core}"
MQTT_CT_TEMPLATE_FILE="${MQTT_CT_TEMPLATE_FILE:-debian-13-standard_13.1-2_amd64.tar.zst}"
MQTT_CT_ROOTFS_SIZE="${MQTT_CT_ROOTFS_SIZE:-8}"
MQTT_CT_MEMORY_MB="${MQTT_CT_MEMORY_MB:-512}"
MQTT_CT_SWAP_MB="${MQTT_CT_SWAP_MB:-256}"
MQTT_CT_CORES="${MQTT_CT_CORES:-1}"
MQTT_CT_IP_CONFIG="${MQTT_CT_IP_CONFIG:-dhcp}"
MQTT_CT_UNPRIVILEGED="${MQTT_CT_UNPRIVILEGED:-1}"
MQTT_CT_ONBOOT="${MQTT_CT_ONBOOT:-1}"

PROXMOX_BRIDGE="${PROXMOX_BRIDGE:-vmbr0}"
PROXMOX_TEMPLATE_STORAGE="${PROXMOX_TEMPLATE_STORAGE:-local}"
PROXMOX_CT_STORAGE="${PROXMOX_CT_STORAGE:-local-lvm}"

TEMPLATE_PATH="/var/lib/vz/template/cache/${MQTT_CT_TEMPLATE_FILE}"

run_host() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[DRY-RUN] $*"
  else
    "$@"
  fi
}

run_ct() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[DRY-RUN] pct exec ${MQTT_CT_ID} -- $*"
  else
    pct exec "${MQTT_CT_ID}" -- "$@"
  fi
}

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required host commands..."
for cmd in pct pveam grep awk; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Required command not found: ${cmd}"
    exit 1
  fi
done

log_info "Checking Proxmox bridge ${PROXMOX_BRIDGE}..."
if ! ip link show "${PROXMOX_BRIDGE}" >/dev/null 2>&1; then
  log_error "Bridge does not exist: ${PROXMOX_BRIDGE}"
  exit 1
fi

log_info "Checking whether CT ${MQTT_CT_ID} already exists..."
if pct config "${MQTT_CT_ID}" >/dev/null 2>&1; then
  log_info "CT ${MQTT_CT_ID} already exists"
else
  log_info "CT ${MQTT_CT_ID} does not exist and will be created"

  log_info "Checking template availability: ${MQTT_CT_TEMPLATE_FILE}"
  if [[ ! -f "${TEMPLATE_PATH}" ]]; then
    log_info "Template not found locally, downloading..."
    run_host pveam download "${PROXMOX_TEMPLATE_STORAGE}" "${MQTT_CT_TEMPLATE_FILE}"
  else
    log_info "Template already exists: ${TEMPLATE_PATH}"
  fi

  log_info "Creating CT ${MQTT_CT_ID} (${MQTT_CT_HOSTNAME})..."
  run_host pct create "${MQTT_CT_ID}" "${TEMPLATE_PATH}" \
    --hostname "${MQTT_CT_HOSTNAME}" \
    --rootfs "${PROXMOX_CT_STORAGE}:${MQTT_CT_ROOTFS_SIZE}" \
    --memory "${MQTT_CT_MEMORY_MB}" \
    --swap "${MQTT_CT_SWAP_MB}" \
    --cores "${MQTT_CT_CORES}" \
    --net0 "name=eth0,bridge=${PROXMOX_BRIDGE},ip=${MQTT_CT_IP_CONFIG}" \
    --unprivileged "${MQTT_CT_UNPRIVILEGED}" \
    --onboot "${MQTT_CT_ONBOOT}" \
    --features "keyctl=1"
fi

log_info "Ensuring CT ${MQTT_CT_ID} is started..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] pct status ${MQTT_CT_ID}"
  log_info "[DRY-RUN] pct start ${MQTT_CT_ID} if not running"
  log_info "Dry-run completed successfully"
  log_info "No CT was created or modified because --dry-run was used"
  exit 0
fi

if ! pct status "${MQTT_CT_ID}" | grep -q "status: running"; then
  run_host pct start "${MQTT_CT_ID}"
fi

log_info "Waiting for CT ${MQTT_CT_ID} to become ready..."
for i in {1..30}; do
  if pct exec "${MQTT_CT_ID}" -- true >/dev/null 2>&1; then
    log_info "CT ${MQTT_CT_ID} is ready"
    break
  fi

  if [[ "${i}" -eq 30 ]]; then
    log_error "CT ${MQTT_CT_ID} did not become ready in time"
    exit 1
  fi

  sleep 2
done

log_info "Waiting for network inside CT ${MQTT_CT_ID}..."
for i in {1..30}; do
  if pct exec "${MQTT_CT_ID}" -- ip -4 addr show eth0 | grep -q 'inet '; then
    log_info "IPv4 address detected on eth0"
    break
  fi

  if [[ "${i}" -eq 30 ]]; then
    log_error "No IPv4 address detected on eth0"
    exit 1
  fi

  sleep 2
done

log_info "Checking DNS inside CT ${MQTT_CT_ID}..."
for i in {1..10}; do
  if pct exec "${MQTT_CT_ID}" -- getent hosts deb.debian.org >/dev/null 2>&1; then
    log_info "DNS resolution works"
    break
  fi

  if [[ "${i}" -eq 10 ]]; then
    log_error "DNS resolution failed inside CT ${MQTT_CT_ID}"
    exit 1
  fi

  sleep 2
done

log_info "Installing Mosquitto inside CT ${MQTT_CT_ID}..."
run_ct apt-get update
run_ct apt-get install -y mosquitto mosquitto-clients

log_info "Configuring Mosquitto listener..."
run_ct mkdir -p /etc/mosquitto/conf.d

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] write /etc/mosquitto/conf.d/homelab.conf"
else
  pct exec "${MQTT_CT_ID}" -- bash -c "cat > /etc/mosquitto/conf.d/homelab.conf" <<'EOF'
listener 1883 0.0.0.0
allow_anonymous true
log_dest syslog
log_dest stdout
EOF
fi

log_info "Enabling and starting Mosquitto..."
run_ct systemctl enable mosquitto
run_ct systemctl restart mosquitto

log_info "Validating Mosquitto service..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] systemctl is-active mosquitto"
else
  if pct exec "${MQTT_CT_ID}" -- systemctl is-active --quiet mosquitto; then
    log_info "Mosquitto service is active"
  else
    log_error "Mosquitto service is not active"
    pct exec "${MQTT_CT_ID}" -- journalctl -u mosquitto --no-pager -n 80 || true
    exit 1
  fi
fi

log_info "Validating MQTT port 1883..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] ss -ltnp | grep ':1883'"
else
  if pct exec "${MQTT_CT_ID}" -- ss -ltnp | grep -q ':1883'; then
    log_info "Mosquitto is listening on TCP port 1883"
  else
    log_error "Mosquitto is not listening on TCP port 1883"
    exit 1
  fi
fi

log_info "Running local MQTT publish/subscribe test..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] mosquitto_sub / mosquitto_pub local test"
else
  TEST_TOPIC="homelab/validation"
  TEST_MESSAGE="mqtt-validation-ok"

  pct exec "${MQTT_CT_ID}" -- bash -c "
    timeout 5 mosquitto_sub -h 127.0.0.1 -t '${TEST_TOPIC}' -C 1 > /tmp/mqtt-validation.out &
    sub_pid=\$!
    sleep 1
    mosquitto_pub -h 127.0.0.1 -t '${TEST_TOPIC}' -m '${TEST_MESSAGE}'
    wait \${sub_pid}
    grep -qx '${TEST_MESSAGE}' /tmp/mqtt-validation.out
    rm -f /tmp/mqtt-validation.out
  "

  log_info "Local MQTT publish/subscribe test succeeded"
fi

MQTT_CT_IP="$(
  pct exec "${MQTT_CT_ID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true
)"

log_info "MQTT deployment completed successfully"

if [[ -n "${MQTT_CT_IP}" ]]; then
  log_info "MQTT broker address: ${MQTT_CT_IP}:1883"
else
  log_warn "Could not determine MQTT CT IP address"
fi
