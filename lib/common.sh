#!/usr/bin/env bash
set -euo pipefail

# Load logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./logging.sh
source "${SCRIPT_DIR}/logging.sh"

die() {
    log_error "$1"
    exit 1
}

run_cmd() {
    log_info "Running: $*"
    "$@"
}

confirm() {
    local prompt="${1:-Are you sure?}"
    read -r -p "$prompt [y/N]: " response
    [[ "$response" =~ ^[yY]$ ]]
}
