#!/usr/bin/env bash

nextcloud::logs::log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $*"
}

nextcloud::logs::info() {
    nextcloud::logs::log "INFO" "$@"
}

nextcloud::logs::warn() {
    nextcloud::logs::log "WARN" "$@"
}

nextcloud::logs::error() {
    nextcloud::logs::log "ERROR" "$@"
}

nextcloud::logs::init() {
    mkdir -p "${SCRIPT_DIR}/logs"
    LOG_FILE="${SCRIPT_DIR}/logs/backup_nextcloud.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
}