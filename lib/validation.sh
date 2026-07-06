#!/usr/bin/env bash
set -euo pipefail

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "Must run as root"
        exit 1
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: Required command not found: $1"
        exit 1
    }
}

require_directory() {
    [[ -d "$1" ]] || {
        echo "ERROR: Required directory missing: $1"
        exit 1
    }
}
