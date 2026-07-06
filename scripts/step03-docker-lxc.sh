#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Framework bootstrap
# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../config/defaults.conf
source "${ROOT_DIR}/config/defaults.conf"

# shellcheck source=../lib/cli.sh
source "${ROOT_DIR}/lib/cli.sh"

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"

# shellcheck source=../lib/validation.sh
source "${ROOT_DIR}/lib/validation.sh"

parse_cli_args "$@"

# ------------------------------------------------------------
# Validation counters
# ------------------------------------------------------------

VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0

# ------------------------------------------------------------
# Desired state
# ------------------------------------------------------------
CT_ID="${DOCKER_CT_ID}"
CT_HOSTNAME="${DOCKER_CT_HOSTNAME}"
CT_TEMPLATE_STORAGE="${PROXMOX_TEMPLATE_STORAGE}"
CT_TEMPLATE_FILE="${DOCKER_CT_TEMPLATE_FILE}"
CT_STORAGE="${PROXMOX_CT_STORAGE}"
CT_ROOTFS_SIZE="${DOCKER_CT_ROOTFS_SIZE}"
CT_MEMORY_MB="${DOCKER_CT_MEMORY_MB}"
CT_SWAP_MB="${DOCKER_CT_SWAP_MB}"
CT_CORES="${DOCKER_CT_CORES}"
CT_BRIDGE="${PROXMOX_BRIDGE}"
CT_IP_CONFIG="${DOCKER_CT_IP_CONFIG}"
CT_UNPRIVILEGED="${DOCKER_CT_UNPRIVILEGED}"
CT_ONBOOT="${DOCKER_CT_ONBOOT}"
CT_FEATURES="${DOCKER_CT_FEATURES}"
CT_MOUNTPOINT_MP0="${DOCKER_CT_MOUNTPOINT_MP0}"


TEMPLATE_PATH="/var/lib/vz/template/cache/${CT_TEMPLATE_FILE}"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

run_or_print() {
    if [[ "${RUNTIME_DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] $*"
    else
        log_info "Running: $*"
        "$@"
    fi
}

pct_container_exists() {
    pct status "${CT_ID}" >/dev/null 2>&1
}

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

log_info "======================================"
log_info "STEP 03 - DOCKER LXC FOUNDATION"
log_info "======================================"

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

log_info "Checking root access..."
if ! require_root; then
    ((VALIDATION_ERRORS+=1))
fi

# ------------------------------------------------------------
# Required commands
# ------------------------------------------------------------

log_info "Checking required commands..."

required_commands=(
    pct
    pveam
    pvesm
    pveversion
    ip
    awk
    grep
    sed
)

for cmd in "${required_commands[@]}"; do
    if ! require_command "${cmd}"; then
        ((VALIDATION_ERRORS+=1))
    fi
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
    log_error "Cannot continue because required checks failed"
    exit 1
fi

# ------------------------------------------------------------
# Proxmox sanity checks
# ------------------------------------------------------------

log_info "Checking Proxmox version..."
if pveversion >/dev/null 2>&1; then
    log_info "Proxmox version: $(pveversion)"
else
    log_error "Unable to determine Proxmox version"
    ((VALIDATION_ERRORS+=1))
fi

# ------------------------------------------------------------
# Storage validation
# ------------------------------------------------------------

log_info "Checking container storage target..."
if pvesm status | awk '{print $1}' | grep -Fxq "${CT_STORAGE}"; then
    log_info "Container storage exists: ${CT_STORAGE}"
else
    log_error "Container storage not found: ${CT_STORAGE}"
    ((VALIDATION_ERRORS+=1))
fi

log_info "Checking template storage target..."
if pvesm status | awk '{print $1}' | grep -Fxq "${CT_TEMPLATE_STORAGE}"; then
    log_info "Template storage exists: ${CT_TEMPLATE_STORAGE}"
else
    log_error "Template storage not found: ${CT_TEMPLATE_STORAGE}"
    ((VALIDATION_ERRORS+=1))
fi

# ------------------------------------------------------------
# Bridge validation
# ------------------------------------------------------------

log_info "Checking network bridge..."
if ip link show "${CT_BRIDGE}" >/dev/null 2>&1; then
    log_info "Bridge exists: ${CT_BRIDGE}"
else
    log_error "Bridge not found: ${CT_BRIDGE}"
    ((VALIDATION_ERRORS+=1))
fi

# ------------------------------------------------------------
# Bind mount validation
# ------------------------------------------------------------

log_info "Checking Frigate storage bind mount source..."
if [[ -d "/mnt/frigate" ]]; then
    log_info "Bind mount source exists: /mnt/frigate"
else
    log_error "Bind mount source missing: /mnt/frigate"
    ((VALIDATION_ERRORS+=1))
fi

# ------------------------------------------------------------
# Template validation
# ------------------------------------------------------------

log_info "Checking LXC template..."
if [[ -f "${TEMPLATE_PATH}" ]]; then
    log_info "Template exists: ${TEMPLATE_PATH}"
else
    log_warn "Template missing locally: ${TEMPLATE_PATH}"
    ((VALIDATION_WARNINGS+=1))
    log_warn "Download it with: pveam update && pveam download ${CT_TEMPLATE_STORAGE} ${CT_TEMPLATE_FILE}"
fi

# ------------------------------------------------------------
# Existing container validation
# ------------------------------------------------------------

log_info "Checking whether CT ${CT_ID} already exists..."
if pct_container_exists; then
    existing_status="$(pct status "${CT_ID}" 2>/dev/null || true)"
    log_warn "Container already exists: CT ${CT_ID}"
    log_info "Existing status: ${existing_status}"
    ((VALIDATION_WARNINGS+=1))
else
    log_info "Container does not exist yet: CT ${CT_ID}"
fi

# ------------------------------------------------------------
# Stop if critical validation failed
# ------------------------------------------------------------

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
    log_error "Validation FAILED with ${VALIDATION_ERRORS} error(s)"
    exit 1
fi

# ------------------------------------------------------------
# Require local template for safety
# ------------------------------------------------------------

if [[ ! -f "${TEMPLATE_PATH}" ]]; then
    log_error "Template is not present locally, refusing to auto-download in this step"
    log_error "Run: pveam update && pveam download ${CT_TEMPLATE_STORAGE} ${CT_TEMPLATE_FILE}"
    exit 1
fi

# ------------------------------------------------------------
# Create container if absent
# ------------------------------------------------------------

if pct_container_exists; then
    log_info "Skipping create because CT ${CT_ID} already exists"
else
    log_info "Creating CT ${CT_ID}..."

    run_or_print pct create "${CT_ID}" "${TEMPLATE_PATH}" \
        --hostname "${CT_HOSTNAME}" \
        --ostype debian \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS_SIZE}" \
        --memory "${CT_MEMORY_MB}" \
        --swap "${CT_SWAP_MB}" \
        --cores "${CT_CORES}" \
        --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP_CONFIG}" \
        --unprivileged "${CT_UNPRIVILEGED}" \
        --onboot "${CT_ONBOOT}" \
        --features "${CT_FEATURES}" \
        --mp0 "${CT_MOUNTPOINT_MP0}"
fi

# ------------------------------------------------------------
# Post-create validation
# ------------------------------------------------------------

log_info "Validating resulting container state..."

if pct_container_exists; then
    log_info "Container now exists: CT ${CT_ID}"
    while IFS= read -r line; do
        log_info "${line}"
    done < <(pct config "${CT_ID}")
else
    if [[ "${RUNTIME_DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] Skipping post-create existence check failure"
    else
        log_error "Container creation appears to have failed: CT ${CT_ID}"
        exit 1
    fi
fi

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

log_info "======================================"
log_info "DOCKER LXC FOUNDATION COMPLETE"
log_info "======================================"
log_info "Warnings: ${VALIDATION_WARNINGS}"
log_info "Errors: ${VALIDATION_ERRORS}"
