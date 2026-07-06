#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/lib/common.sh"

log_info "Testing logging..."
log_info "INFO message"
log_warn "WARN message"
log_error "ERROR message"
log_debug "DEBUG message (only visible in debug mode)"

log_info "Testing CLI flags..."

source "${ROOT_DIR}/lib/cli.sh"
parse_cli_args --debug --verbose


log_info "DEBUG=$RUNTIME_DEBUG"
log_info "VERBOSE=$RUNTIME_VERBOSE"
log_info "DRY_RUN=$RUNTIME_DRY_RUN"
log_info "ASSUME_YES=$RUNTIME_ASSUME_YES"


log_info "Testing validation..."

source "${ROOT_DIR}/lib/validation.sh"
require_command bash
require_directory "/tmp"

log_info "All framework tests passed"
