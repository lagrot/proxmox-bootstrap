#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
STEP20_SCRIPT_DIR="${PROJECT_ROOT}/scripts"

TARGET="${1:-}"
[[ "${EUID}" -eq 0 ]] || die "Run as root"
[[ -n "${TARGET}" ]] || die "Usage: $0 {proxmox|ct200|docker|ct210|mqtt|ct220|hermes|homeassistant|frigate|zigbee}"

run() {
  log_info "Running post-update validation: $*"
  "$@"
}

case "${TARGET}" in
  proxmox)
    run bash "${STEP20_SCRIPT_DIR}/step01-host-validation.sh"
    run bash "${STEP20_SCRIPT_DIR}/step04b-frigate-validation.sh"
    run bash "${STEP20_SCRIPT_DIR}/step10i-frigate-tpu-validation.sh"
    run bash "${STEP20_SCRIPT_DIR}/step06b-homeassistant-validation.sh"
    run bash "${STEP20_SCRIPT_DIR}/step19b-homeassistant-zigbee-validation.sh"
    ;;
  ct200|docker)
    run bash "${STEP20_SCRIPT_DIR}/step04b-frigate-validation.sh"
    run bash "${STEP20_SCRIPT_DIR}/step10i-frigate-tpu-validation.sh"
    run bash "${STEP20_SCRIPT_DIR}/step10j-frigate-gpu-validation.sh"
    run bash "${STEP20_SCRIPT_DIR}/step10n-frigate-homeassistant-smoketest.sh"
    ;;
  ct210|mqtt)
    run bash "${STEP20_SCRIPT_DIR}/step05b-mqtt-validation.sh"
    run bash "${STEP20_SCRIPT_DIR}/step05d-mqtt-auth-validation.sh"
    run bash "${STEP20_SCRIPT_DIR}/step10f-frigate-mqtt-validation.sh"
    ;;
  ct220|hermes)
    run bash "${STEP20_SCRIPT_DIR}/step08b-hermes-validation.sh"
    run bash "${STEP20_SCRIPT_DIR}/step08d-hermes-validation.sh"
    run bash "${STEP20_SCRIPT_DIR}/step08f-hermes-gateway-validation.sh"
    ;;
  homeassistant)
    run bash "${STEP20_SCRIPT_DIR}/step06b-homeassistant-validation.sh"
    run bash "${STEP20_SCRIPT_DIR}/step19b-homeassistant-zigbee-validation.sh"
    run bash "${STEP20_SCRIPT_DIR}/step10n-frigate-homeassistant-smoketest.sh"
    ;;
  frigate)
    current_version="$(pct exec 200 -- curl -fsS http://127.0.0.1:5000/api/version)"
    run bash "${STEP20_SCRIPT_DIR}/step18c-frigate-post-upgrade-validation.sh" \
      --expected-version "${current_version%%-*}" --baseline-test
    ;;
  zigbee)
    run bash "${STEP20_SCRIPT_DIR}/step19b-homeassistant-zigbee-validation.sh"
    ;;
  *)
    die "Unknown validation target: ${TARGET}"
    ;;
esac

log_info "Post-update validation passed for ${TARGET}"
