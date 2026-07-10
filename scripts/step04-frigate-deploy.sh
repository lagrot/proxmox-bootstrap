#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

log_info "======================================"
log_info "STEP 04 - FRIGATE DEPLOYMENT"
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

Deploy a minimal Frigate Docker Compose setup inside CT ${DOCKER_CT_ID:-200}.
EOF
      exit 0
      ;;
    *)
      log_error "Unknown argument: ${arg}"
      exit 1
      ;;
  esac
done

CT_ID="${DOCKER_CT_ID:-200}"
FRIGATE_APP_DIR="${FRIGATE_APP_DIR:-/opt/frigate}"
FRIGATE_CONFIG_DIR="${FRIGATE_CONFIG_DIR:-${FRIGATE_APP_DIR}/config}"
FRIGATE_MEDIA_DIR="${FRIGATE_MEDIA_DIR:-/mnt/frigate}"
FRIGATE_IMAGE="${FRIGATE_IMAGE:-ghcr.io/blakeblackshear/frigate:stable}"
FRIGATE_WEB_PORT="${FRIGATE_WEB_PORT:-8971}"

run_host() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[DRY-RUN] $*"
  else
    "$@"
  fi
}

run_ct() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[DRY-RUN] pct exec ${CT_ID} -- $*"
  else
    pct exec "${CT_ID}" -- "$@"
  fi
}

push_file_to_ct() {
  local src="$1"
  local dst="$2"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "[DRY-RUN] pct push ${CT_ID} ${src} ${dst}"
  else
    pct push "${CT_ID}" "${src}" "${dst}"
  fi
}

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking required commands on host..."
for cmd in pct grep mktemp; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Required command not found on host: ${cmd}"
    exit 1
  fi
done

log_info "Checking whether CT ${CT_ID} exists..."
if ! pct config "${CT_ID}" >/dev/null 2>&1; then
  log_error "CT ${CT_ID} does not exist"
  exit 1
fi

log_info "Ensuring CT ${CT_ID} is running..."
if ! pct status "${CT_ID}" | grep -q "status: running"; then
  run_host pct start "${CT_ID}"
fi

log_info "Checking Docker inside CT ${CT_ID}..."
run_ct docker version >/dev/null
run_ct docker compose version >/dev/null

log_info "Checking Docker service inside CT ${CT_ID}..."
if ! pct exec "${CT_ID}" -- systemctl is-active --quiet docker; then
  log_error "Docker is not active inside CT ${CT_ID}"
  exit 1
fi

log_info "Installing camera diagnostic dependency FFmpeg inside CT ${CT_ID}..."
run_ct bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends ffmpeg'

log_info "Checking Frigate media mount inside CT ${CT_ID}..."
if ! pct exec "${CT_ID}" -- test -d "${FRIGATE_MEDIA_DIR}"; then
  log_error "${FRIGATE_MEDIA_DIR} does not exist inside CT ${CT_ID}"
  exit 1
fi
log_info "Preparing Frigate media directories and permissions on host..."

if [[ "${FRIGATE_MEDIA_DIR}" != /mnt/frigate* ]]; then
  log_error "Refusing to modify unexpected Frigate media path: ${FRIGATE_MEDIA_DIR}"
  exit 1
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] mkdir -p ${FRIGATE_MEDIA_DIR}/{clips,clips/thumbs,recordings,snapshots,exports}"
  log_info "[DRY-RUN] chown -R 100000:100000 ${FRIGATE_MEDIA_DIR}"
  log_info "[DRY-RUN] chmod -R 775 ${FRIGATE_MEDIA_DIR}"
else
  mkdir -p \
    "${FRIGATE_MEDIA_DIR}/clips" \
    "${FRIGATE_MEDIA_DIR}/clips/thumbs" \
    "${FRIGATE_MEDIA_DIR}/recordings" \
    "${FRIGATE_MEDIA_DIR}/snapshots" \
    "${FRIGATE_MEDIA_DIR}/exports"

  chown -R 100000:100000 "${FRIGATE_MEDIA_DIR}"
  chmod -R 775 "${FRIGATE_MEDIA_DIR}"
fi
for dir in clips clips/thumbs recordings snapshots exports; do
  if ! pct exec "${CT_ID}" -- test -d "${FRIGATE_MEDIA_DIR}/${dir}"; then
    log_error "${FRIGATE_MEDIA_DIR}/${dir} does not exist inside CT ${CT_ID}"
    exit 1
  fi
done

log_info "Validating CT write access to Frigate media directory..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "[DRY-RUN] pct exec ${CT_ID} -- touch ${FRIGATE_MEDIA_DIR}/.ct-write-test"
  log_info "[DRY-RUN] pct exec ${CT_ID} -- rm -f ${FRIGATE_MEDIA_DIR}/.ct-write-test"
else
  if pct exec "${CT_ID}" -- touch "${FRIGATE_MEDIA_DIR}/.ct-write-test"; then
    pct exec "${CT_ID}" -- rm -f "${FRIGATE_MEDIA_DIR}/.ct-write-test"
  else
    log_error "CT ${CT_ID} cannot write to ${FRIGATE_MEDIA_DIR}"
    exit 1
  fi
fi

log_info "Checking iGPU visibility inside CT ${CT_ID}..."
if ! pct exec "${CT_ID}" -- test -e /dev/dri/renderD128; then
  log_error "/dev/dri/renderD128 is not visible inside CT ${CT_ID}"
  exit 1
fi

log_info "Checking USB bus visibility inside CT ${CT_ID}..."
if ! pct exec "${CT_ID}" -- test -d /dev/bus/usb; then
  log_error "/dev/bus/usb is not visible inside CT ${CT_ID}"
  exit 1
fi

log_info "Creating Frigate directories inside CT ${CT_ID}..."
run_ct mkdir -p "${FRIGATE_CONFIG_DIR}"
run_ct mkdir -p "${FRIGATE_MEDIA_DIR}/recordings" "${FRIGATE_MEDIA_DIR}/snapshots" "${FRIGATE_MEDIA_DIR}/exports"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

COMPOSE_FILE="${TMP_DIR}/docker-compose.yml"
CONFIG_FILE="${TMP_DIR}/config.yml"

log_info "Rendering docker-compose.yml..."
cat > "${COMPOSE_FILE}" <<EOF
services:
  frigate:
    container_name: frigate
    image: ${FRIGATE_IMAGE}
    restart: unless-stopped
    privileged: true
    cap_add:
      - CAP_PERFMON
    shm_size: "512mb"
    stop_grace_period: 30s
    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128
      - /dev/bus/usb:/dev/bus/usb
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ${FRIGATE_CONFIG_DIR}:/config
      - ${FRIGATE_MEDIA_DIR}:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 1000000000
    ports:
      - "${FRIGATE_WEB_PORT}:8971"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
EOF

log_info "Rendering minimal Frigate config.yml..."
cat > "${CONFIG_FILE}" <<'EOF'
mqtt:
  enabled: false

ffmpeg:
  hwaccel_args: preset-vaapi

telemetry:
  stats:
    intel_gpu_stats: true

detectors:
  coral:
    type: edgetpu
    device: usb

record:
  enabled: true
  retain:
    days: 7
    mode: motion

snapshots:
  enabled: true
  retain:
    default: 30

cameras: {}
EOF

log_info "Copying Frigate files into CT ${CT_ID}..."
push_file_to_ct "${COMPOSE_FILE}" "${FRIGATE_APP_DIR}/docker-compose.yml"
push_file_to_ct "${CONFIG_FILE}" "${FRIGATE_CONFIG_DIR}/config.yml"

log_info "Validating Docker Compose file..."
run_ct bash -c "cd '${FRIGATE_APP_DIR}' && docker compose config >/dev/null"

log_info "Pulling Frigate image..."
run_ct bash -c "cd '${FRIGATE_APP_DIR}' && docker compose pull"

log_info "Starting Frigate..."
run_ct bash -c "cd '${FRIGATE_APP_DIR}' && docker compose up -d"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "Dry-run completed successfully"
  log_info "No container was started because --dry-run was used"
  exit 0
fi

log_info "Waiting briefly for Frigate container state..."
sleep 10
log_info "Checking Frigate container status..."
if pct exec "${CT_ID}" -- docker ps --format '{{.Names}}' | grep -qx 'frigate'; then
  log_info "Frigate container is running"
else
  log_error "Frigate container is not running"
  log_info "Recent Frigate logs:"
  pct exec "${CT_ID}" -- docker logs --tail 80 frigate || true
  exit 1
fi

log_info "Checking Frigate web port inside CT ${CT_ID}..."
if pct exec "${CT_ID}" -- bash -c "command -v curl >/dev/null 2>&1"; then
  HTTP_CODE="$(
    pct exec "${CT_ID}" -- curl -k -s -o /dev/null -w '%{http_code}' "https://127.0.0.1:${FRIGATE_WEB_PORT}" || true
  )"

  case "${HTTP_CODE}" in
    200|301|302|307|308|400|401|403)
      log_info "Frigate web service is responding on HTTPS port ${FRIGATE_WEB_PORT} with HTTP ${HTTP_CODE}"
      ;;
    000|"")
      log_warn "Frigate web service did not respond on HTTPS port ${FRIGATE_WEB_PORT}"
      ;;
    *)
      log_warn "Frigate web service returned unexpected HTTP status over HTTPS: ${HTTP_CODE}"
      ;;
  esac
else
  log_warn "curl is not installed inside CT ${CT_ID}; skipping HTTPS validation"
fi
log_info "Frigate deployment completed successfully"
log_info "Frigate URL should be available at: https://<CT-IP>:${FRIGATE_WEB_PORT}"
