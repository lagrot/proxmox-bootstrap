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

CT_ID="200"
CT_NAME="docker-core"
EXPECTED_MOUNTPOINT="/mnt/frigate"
CONTAINER_WAIT_SECONDS="15"

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

pct_exec_or_print() {
    if [[ "${RUNTIME_DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] pct exec ${CT_ID} -- $*"
    else
        log_info "Running in CT ${CT_ID}: $*"
        pct exec "${CT_ID}" -- "$@"
    fi
}

container_exists() {
    pct status "${CT_ID}" >/dev/null 2>&1
}

container_is_running() {
    pct status "${CT_ID}" 2>/dev/null | grep -q '^status: running$'
}

wait_for_container() {
    local seconds_waited=0

    while [[ "${seconds_waited}" -lt "${CONTAINER_WAIT_SECONDS}" ]]; do
        if pct exec "${CT_ID}" -- true >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
        seconds_waited=$((seconds_waited + 1))
    done

    return 1
}

wait_for_container_network() {
    local seconds_waited=0

    while [[ "${seconds_waited}" -lt "${CONTAINER_WAIT_SECONDS}" ]]; do
        if pct exec "${CT_ID}" -- bash -c 'ip -4 addr show dev eth0 | grep -q "inet " && ip route | grep -q "^default"' >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
        seconds_waited=$((seconds_waited + 1))
    done

    return 1
}

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

log_info "======================================"
log_info "STEP 03B - DOCKER-CORE BOOTSTRAP"
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
    grep
    sleep
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
# Container existence
# ------------------------------------------------------------

log_info "Checking whether CT ${CT_ID} exists..."
if container_exists; then
    log_info "Container exists: CT ${CT_ID}"
else
    log_error "Container does not exist: CT ${CT_ID}"
    log_error "Run step03-docker-lxc.sh first"
    exit 1
fi

# ------------------------------------------------------------
# Start container if needed
# ------------------------------------------------------------

log_info "Checking container runtime state..."
if container_is_running; then
    log_info "Container is already running"
else
    log_info "Container is stopped"
    run_or_print pct start "${CT_ID}"
fi

# ------------------------------------------------------------
# Wait for exec readiness
# ------------------------------------------------------------

if [[ "${RUNTIME_DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] Skipping wait for container readiness"
else
    log_info "Waiting for container to become ready..."
    if wait_for_container; then
        log_info "Container is ready for commands"
    else
        log_error "Container did not become ready within ${CONTAINER_WAIT_SECONDS} seconds"
        exit 1
    fi
fi

# ------------------------------------------------------------
# Basic OS validation
# ------------------------------------------------------------

log_info "Checking container OS details..."
pct_exec_or_print bash -c 'cat /etc/os-release'

# ------------------------------------------------------------
# Basic network validation
# ------------------------------------------------------------

log_info "Checking container network..."
pct_exec_or_print bash -c 'ip addr show'
pct_exec_or_print bash -c 'ip route'

if [[ "${RUNTIME_DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] Skipping network readiness wait"
else
    log_info "Waiting for IPv4 address and default route inside container..."
    if wait_for_container_network; then
        log_info "Container network is ready"
    else
        log_error "Container network did not become ready within ${CONTAINER_WAIT_SECONDS} seconds"
        exit 1
    fi
fi

log_info "Checking DNS resolution inside container..."
if [[ "${RUNTIME_DRY_RUN:-false}" == "true" ]]; then
    log_info "[DRY-RUN] pct exec ${CT_ID} -- getent hosts deb.debian.org"
else
    dns_ready=false

    for _ in $(seq 1 10); do
        if pct exec "${CT_ID}" -- getent hosts deb.debian.org >/dev/null 2>&1; then
            dns_ready=true
            break
        fi
        sleep 1
    done

    if [[ "${dns_ready}" == "true" ]]; then
        log_info "DNS resolution is working inside container"
        pct exec "${CT_ID}" -- getent hosts deb.debian.org
    else
        log_error "DNS resolution failed inside container"
        exit 1
    fi
fi

# ------------------------------------------------------------
# Check bind mount visibility
# ------------------------------------------------------------

log_info "Checking Frigate storage visibility inside container..."
pct_exec_or_print bash -c "test -d ${EXPECTED_MOUNTPOINT}"
pct_exec_or_print bash -c "mount | grep ' ${EXPECTED_MOUNTPOINT} ' || true"
pct_exec_or_print bash -c "ls -la ${EXPECTED_MOUNTPOINT}"

# ------------------------------------------------------------
# Install prerequisites
# ------------------------------------------------------------

log_info "Installing Docker prerequisites..."
pct_exec_or_print bash -c 'apt-get update'
pct_exec_or_print bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg'

# ------------------------------------------------------------
# Configure Docker repository
# ------------------------------------------------------------

log_info "Configuring Docker apt repository..."
pct_exec_or_print bash -c 'install -m 0755 -d /etc/apt/keyrings'
pct_exec_or_print bash -c 'curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc'
pct_exec_or_print bash -c 'chmod a+r /etc/apt/keyrings/docker.asc'
pct_exec_or_print bash -c 'arch="$(dpkg --print-architecture)"; codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"; echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable" > /etc/apt/sources.list.d/docker.list'


# ------------------------------------------------------------
# Install Docker Engine
# ------------------------------------------------------------

log_info "Installing Docker Engine and Compose plugin..."
pct_exec_or_print bash -c 'apt-get update'
pct_exec_or_print bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin'

# ------------------------------------------------------------
# Enable and start Docker
# ------------------------------------------------------------

log_info "Enabling and starting Docker..."
pct_exec_or_print bash -c 'systemctl enable docker'
pct_exec_or_print bash -c 'systemctl start docker'

# ------------------------------------------------------------
# Validate Docker installation
# ------------------------------------------------------------

log_info "Validating Docker installation..."
pct_exec_or_print bash -c 'docker --version'
pct_exec_or_print bash -c 'docker compose version'
pct_exec_or_print bash -c 'systemctl is-active docker'

# ------------------------------------------------------------
# Final storage verification inside CT
# ------------------------------------------------------------

log_info "Validating Frigate storage layout inside container..."
pct_exec_or_print bash -c "find ${EXPECTED_MOUNTPOINT} -maxdepth 1 -type d | sort"

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

log_info "======================================"
log_info "DOCKER-CORE BOOTSTRAP COMPLETE"
log_info "======================================"
log_info "Warnings: ${VALIDATION_WARNINGS}"
log_info "Errors: ${VALIDATION_ERRORS}"
