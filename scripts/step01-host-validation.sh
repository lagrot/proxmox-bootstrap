#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Framework bootstrap
# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
# Header
# ------------------------------------------------------------

log_info "======================================"
log_info "STEP 01 - PROXMOX HOST VALIDATION"
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

for cmd in lscpu lsmod systemctl pveversion; do
    if ! require_command "$cmd"; then
        ((VALIDATION_ERRORS+=1))
    fi
done

# ------------------------------------------------------------
# CPU virtualization
# ------------------------------------------------------------

log_info "Checking CPU virtualization support..."

if lscpu | grep -Eiq 'vmx|svm'; then
    log_info "CPU virtualization: ENABLED"
else
    log_error "CPU virtualization NOT detected (vmx/svm missing)"
    ((VALIDATION_ERRORS+=1))
fi

# ------------------------------------------------------------
# KVM modules
# ------------------------------------------------------------

log_info "Checking KVM kernel modules..."

if lsmod | grep -q kvm; then
    log_info "KVM module: LOADED"
else
    log_warn "KVM module not loaded (this may be OK in some environments)"
    ((VALIDATION_WARNINGS+=1))
fi

# ------------------------------------------------------------
# Proxmox version
# ------------------------------------------------------------

log_info "Checking Proxmox version..."

if command -v pveversion >/dev/null 2>&1; then
    log_info "Proxmox detected:"
    log_info "$(pveversion)"
else
    log_error "Proxmox not installed or pveversion missing"
    ((VALIDATION_ERRORS+=1))
fi

# ------------------------------------------------------------
# Systemd services
# ------------------------------------------------------------

log_info "Checking Proxmox services..."

services=(
    pvedaemon
    pveproxy
    pvestatd
)

for service in "${services[@]}"; do
    if systemctl is-active --quiet "$service"; then
        log_info "Service OK: $service"
    else
        log_warn "Service NOT active: $service"
        ((VALIDATION_WARNINGS+=1))
    fi
done

# ------------------------------------------------------------
# Storage visibility
# ------------------------------------------------------------

log_info "Checking storage..."

if command -v pvesm >/dev/null 2>&1; then
    log_info "Proxmox storage configured:"
    while IFS= read -r line; do
        log_info "$line"
    done < <(pvesm status)
else
    log_warn "pvesm not available"
    ((VALIDATION_WARNINGS+=1))
fi

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

log_info "======================================"
log_info "HOST VALIDATION COMPLETE"
log_info "======================================"

if [[ "$VALIDATION_ERRORS" -gt 0 ]]; then
    log_error "Validation FAILED with $VALIDATION_ERRORS error(s)"
    exit 1
fi

log_info "Validation passed with $VALIDATION_WARNINGS warning(s)"
