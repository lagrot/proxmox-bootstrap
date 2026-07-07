#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/lib/common.sh"

# shellcheck source=/dev/null
source "${PROJECT_ROOT}/config/defaults.conf"

log_info "======================================"
log_info "STEP 10E - FRIGATE RESTART"
log_info "======================================"

FRIGATE_CT_ID="${DOCKER_CT_ID:-200}"
FRIGATE_APP_DIR="${FRIGATE_APP_DIR:-/opt/frigate}"
FRIGATE_WEB_PORT="${FRIGATE_WEB_PORT:-8971}"

log_info "Checking root access..."
if [[ "${EUID}" -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Checking CT ${FRIGATE_CT_ID}..."
if ! pct status "${FRIGATE_CT_ID}" 2>/dev/null | grep -q "status: running"; then
  log_error "CT ${FRIGATE_CT_ID} is not running"
  exit 1
fi

log_info "Restarting Frigate through Docker Compose..."
pct exec "${FRIGATE_CT_ID}" -- bash -c "cd '${FRIGATE_APP_DIR}' && docker compose restart frigate"

log_info "Waiting for Frigate container to report running..."
for i in {1..30}; do
  if pct exec "${FRIGATE_CT_ID}" -- docker ps --format '{{.Names}}' | grep -qx 'frigate'; then
    log_info "Frigate container is running"
    break
  fi

  if [[ "${i}" -eq 30 ]]; then
    log_error "Frigate container did not start in time"
    pct exec "${FRIGATE_CT_ID}" -- docker logs --tail 120 frigate || true
    exit 1
  fi

  sleep 2
done

log_info "Waiting for Frigate health..."
for i in {1..45}; do
  HEALTH="$(
    pct exec "${FRIGATE_CT_ID}" -- docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' frigate 2>/dev/null || true
  )"

  case "${HEALTH}" in
    healthy|no-healthcheck)
      log_info "Frigate health status: ${HEALTH}"
      break
      ;;
    unhealthy)
      log_error "Frigate container is unhealthy"
      pct exec "${FRIGATE_CT_ID}" -- docker logs --tail 120 frigate || true
      exit 1
      ;;
  esac

  if [[ "${i}" -eq 45 ]]; then
    log_error "Frigate did not become healthy in time; last health status: ${HEALTH}"
    pct exec "${FRIGATE_CT_ID}" -- docker logs --tail 120 frigate || true
    exit 1
  fi

  sleep 2
done

log_info "Checking Frigate HTTPS endpoint inside CT ${FRIGATE_CT_ID}..."
HTTP_CODE="$(
  pct exec "${FRIGATE_CT_ID}" -- curl -k -s -o /dev/null -w '%{http_code}' "https://127.0.0.1:${FRIGATE_WEB_PORT}" || true
)"

case "${HTTP_CODE}" in
  200|301|302|307|308|400|401|403)
    log_info "Frigate HTTPS endpoint responded with HTTP ${HTTP_CODE}"
    ;;
  *)
    log_error "Frigate HTTPS endpoint did not respond as expected; HTTP ${HTTP_CODE}"
    exit 1
    ;;
esac

log_info "Frigate restart completed successfully"
