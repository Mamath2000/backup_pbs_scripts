#!/usr/bin/env bash

logs::init() {
    mkdir -p "$1/logs"
    LOG_FILE="$1/logs/backup_elkarbackup.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

log() {
    local level="$1"; shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message"
}

log::info()  { log "INFO" "$@"; }
log::warn()  { log "WARN" "$@"; }
log::error() { log "ERROR" "$@"; }
log::debug() { [[ "$LOG_LEVEL" == "DEBUG" ]] && log "DEBUG" "$@" || true; }
