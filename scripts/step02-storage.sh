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
TARGET_FRIGATE_MOUNTPOINT="${FRIGATE_MOUNTPOINT}"
TARGET_FRIGATE_FILESYSTEM="${FRIGATE_FILESYSTEM}"
TARGET_FRIGATE_DEVICE_BY_ID="${FRIGATE_DEVICE_BY_ID}"

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

log_info "======================================"
log_info "STEP 02 - FRIGATE STORAGE VALIDATION"
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
    findmnt
    lsblk
    blkid
    readlink
    grep
)

for cmd in "${required_commands[@]}"; do
    if ! require_command "$cmd"; then
        ((VALIDATION_ERRORS+=1))
    fi
done

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
    log_error "Cannot continue because required checks failed"
    exit 1
fi

# ------------------------------------------------------------
# Mountpoint existence
# ------------------------------------------------------------

log_info "Checking mountpoint directory..."

if [[ -d "${FRIGATE_MOUNTPOINT}" ]]; then
    log_info "Mountpoint exists: ${FRIGATE_MOUNTPOINT}"
else
    log_error "Mountpoint missing: ${FRIGATE_MOUNTPOINT}"
    ((VALIDATION_ERRORS+=1))
fi

# ------------------------------------------------------------
# Stable device path
# ------------------------------------------------------------

log_info "Checking stable device identifier..."

if [[ -e "${FRIGATE_DEVICE_BY_ID}" ]]; then
    resolved_device="$(readlink -f "${FRIGATE_DEVICE_BY_ID}")"
    log_info "Stable device path exists: ${FRIGATE_DEVICE_BY_ID}"
    log_info "Resolves to: ${resolved_device}"
else
    log_error "Stable device path missing: ${FRIGATE_DEVICE_BY_ID}"
    ((VALIDATION_ERRORS+=1))
    resolved_device=""
fi

# ------------------------------------------------------------
# Mount status
# ------------------------------------------------------------

log_info "Checking mount status..."

if findmnt --mountpoint "${FRIGATE_MOUNTPOINT}" >/dev/null 2>&1; then
    mounted_source="$(findmnt -n -o SOURCE --mountpoint "${FRIGATE_MOUNTPOINT}")"
    mounted_fstype="$(findmnt -n -o FSTYPE --mountpoint "${FRIGATE_MOUNTPOINT}")"
    mounted_options="$(findmnt -n -o OPTIONS --mountpoint "${FRIGATE_MOUNTPOINT}")"

    log_info "Mountpoint is active"
    log_info "Mounted source: ${mounted_source}"
    log_info "Mounted filesystem: ${mounted_fstype}"
    log_info "Mounted options: ${mounted_options}"
else
    log_error "Mountpoint is not mounted: ${FRIGATE_MOUNTPOINT}"
    ((VALIDATION_ERRORS+=1))
    mounted_source=""
    mounted_fstype=""
    mounted_options=""
fi

# ------------------------------------------------------------
# Filesystem type validation
# ------------------------------------------------------------

log_info "Checking filesystem type..."

if [[ -n "${mounted_fstype}" ]]; then
    if [[ "${mounted_fstype}" == "${FRIGATE_FILESYSTEM}" ]]; then
        log_info "Filesystem type is correct: ${FRIGATE_FILESYSTEM}"
    else
        log_error "Filesystem type mismatch: expected ${FRIGATE_FILESYSTEM}, got ${mounted_fstype}"
        ((VALIDATION_ERRORS+=1))
    fi
fi

# ------------------------------------------------------------
# Mounted source vs stable path
# ------------------------------------------------------------

log_info "Checking mounted source against stable device path..."

if [[ -n "${resolved_device}" && -n "${mounted_source}" ]]; then
    mounted_source_resolved="$(readlink -f "${mounted_source}")"

    if [[ "${mounted_source_resolved}" == "${resolved_device}" ]]; then
        log_info "Mounted device matches expected stable device"
    else
        log_error "Mounted device mismatch: expected ${resolved_device}, got ${mounted_source_resolved}"
        ((VALIDATION_ERRORS+=1))
    fi
fi

# ------------------------------------------------------------
# blkid validation
# ------------------------------------------------------------

log_info "Checking block device metadata..."

if [[ -n "${resolved_device}" ]]; then
    blkid_output="$(blkid "${resolved_device}" || true)"

    if [[ -n "${blkid_output}" ]]; then
        log_info "blkid: ${blkid_output}"
    else
        log_warn "blkid returned no metadata for ${resolved_device}"
        ((VALIDATION_WARNINGS+=1))
    fi
fi

# ------------------------------------------------------------
# fstab validation
# ------------------------------------------------------------

log_info "Checking /etc/fstab persistence..."

if [[ -f /etc/fstab ]]; then
    fstab_matches="$(grep -E "^[^#].*[[:space:]]${FRIGATE_MOUNTPOINT}[[:space:]]" /etc/fstab || true)"

    if [[ -n "${fstab_matches}" ]]; then
        while IFS= read -r line; do
            log_info "fstab entry: ${line}"
        done <<< "${fstab_matches}"

        if grep -Eq "^[^#]*(UUID=|/dev/disk/by-id/).*[[:space:]]${FRIGATE_MOUNTPOINT}[[:space:]]" /etc/fstab; then
            log_info "fstab uses a stable device reference (UUID or by-id)"
        else
            log_warn "fstab does not use UUID= or /dev/disk/by-id/ for ${FRIGATE_MOUNTPOINT}"
            ((VALIDATION_WARNINGS+=1))
        fi

        if grep -Eq "^[^#].*[[:space:]]${FRIGATE_MOUNTPOINT}[[:space:]]${FRIGATE_FILESYSTEM}[[:space:]]" /etc/fstab; then
            log_info "fstab filesystem type matches expected value"
        else
            log_warn "fstab entry for ${FRIGATE_MOUNTPOINT} does not declare ${FRIGATE_FILESYSTEM}"
            ((VALIDATION_WARNINGS+=1))
        fi
    else
        log_error "No active /etc/fstab entry found for ${FRIGATE_MOUNTPOINT}"
        ((VALIDATION_ERRORS+=1))
    fi
else
    log_error "/etc/fstab is missing"
    ((VALIDATION_ERRORS+=1))
fi

# ------------------------------------------------------------
# Recommended directory layout
# ------------------------------------------------------------

log_info "Ensuring recommended Frigate directory layout exists..."

frigate_directories=(
    "${FRIGATE_MOUNTPOINT}/recordings"
    "${FRIGATE_MOUNTPOINT}/snapshots"
    "${FRIGATE_MOUNTPOINT}/exports"
)

for directory in "${frigate_directories[@]}"; do
    if [[ -d "${directory}" ]]; then
        log_info "Directory exists: ${directory}"
    else
        if [[ "${RUNTIME_DRY_RUN:-false}" == "true" ]]; then
            log_info "[DRY-RUN] Would create directory: ${directory}"
        else
            mkdir -p "${directory}"
            log_info "Created directory: ${directory}"
        fi
    fi
done

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

log_info "======================================"
log_info "FRIGATE STORAGE VALIDATION COMPLETE"
log_info "======================================"

if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
    log_error "Storage validation FAILED with ${VALIDATION_ERRORS} error(s)"
    exit 1
fi

log_info "Storage validation passed with ${VALIDATION_WARNINGS} warning(s)"
