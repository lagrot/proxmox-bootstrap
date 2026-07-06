#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Logging configuration
# ----------------------------

LOG_FILE="${LOG_FILE:-./logs/proxmox-bootstrap.log}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

mkdir -p "$(dirname "$LOG_FILE")"

# ----------------------------
# Log level mapping
# ----------------------------

declare -A LOG_LEVELS=(
    ["DEBUG"]=0
    ["INFO"]=1
    ["WARN"]=2
    ["ERROR"]=3
)

CURRENT_LEVEL="${LOG_LEVELS[$LOG_LEVEL]:-1}"

# ----------------------------
# Colors
# ----------------------------

COLOR_RESET="\033[0m"
COLOR_DEBUG="\033[36m"   # cyan
COLOR_INFO="\033[32m"    # green
COLOR_WARN="\033[33m"    # yellow
COLOR_ERROR="\033[31m"   # red

# ----------------------------
# Helpers
# ----------------------------

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

should_log() {
    local level="$1"
    [[ "${LOG_LEVELS[$level]}" -ge "$CURRENT_LEVEL" ]]
}

log_to_file() {
    local level="$1"
    local message="$2"
    echo "$(timestamp) [$level] $message" >> "$LOG_FILE"
}

log_to_console() {
    local level="$1"
    local message="$2"

    local color=""

    case "$level" in
        DEBUG) color="$COLOR_DEBUG" ;;
        INFO)  color="$COLOR_INFO" ;;
        WARN)  color="$COLOR_WARN" ;;
        ERROR) color="$COLOR_ERROR" ;;
    esac

    echo -e "${color}$(timestamp) [$level] $message${COLOR_RESET}"
}

# ----------------------------
# Core logger
# ----------------------------

log() {
    local level="$1"
    local message="$2"

    should_log "$level" || return 0

    log_to_console "$level" "$message"
    log_to_file "$level" "$message"
}

# ----------------------------
# Public API
# ----------------------------

log_debug() {
    log "DEBUG" "$1"
}

log_info() {
    log "INFO" "$1"
}

log_warn() {
    log "WARN" "$1"
}

log_error() {
    log "ERROR" "$1"
}
