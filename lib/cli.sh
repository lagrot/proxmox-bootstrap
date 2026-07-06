#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=./runtime.sh
source "$(dirname "${BASH_SOURCE[0]}")/runtime.sh"

parse_cli_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --debug)
                RUNTIME_DEBUG=true
                RUNTIME_LOG_LEVEL="DEBUG"
                shift
                ;;
            --verbose)
                RUNTIME_VERBOSE=true
                RUNTIME_LOG_LEVEL="INFO"
                shift
                ;;
            --dry-run)
                RUNTIME_DRY_RUN=true
                shift
                ;;
            --yes)
                RUNTIME_ASSUME_YES=true
                shift
                ;;
            --help)
                echo "Usage: $0 [--debug] [--verbose] [--dry-run] [--yes]"
                exit 0
                ;;
            *)
                echo "Unknown argument: $1"
                exit 1
                ;;
        esac
    done

    export RUNTIME_DEBUG
    export RUNTIME_VERBOSE
    export RUNTIME_DRY_RUN
    export RUNTIME_ASSUME_YES
    export RUNTIME_LOG_LEVEL
}
