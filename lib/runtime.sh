#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Runtime state (global config)
# ----------------------------

RUNTIME_DEBUG=false
RUNTIME_VERBOSE=false
RUNTIME_DRY_RUN=false
RUNTIME_ASSUME_YES=false

RUNTIME_LOG_LEVEL="INFO"

init_runtime() {
	RUNTIME_DEBUG="${RUNTIME_DEBUG:-false}"
	RUNTIME_VERBOSE="${RUNTIME_VERBOSE:-false}"
	RUNTIME_DRY_RUN="${RUNTIME_DRY_RUN:-false}"
	RUNTIME_ASSUME_YES="${RUNTIME_ASSUME_YES:-false}"
       	RUNTIME_LOG_LEVEL="${RUNTIME_LOG_LEVEL:-INFO}"
}
