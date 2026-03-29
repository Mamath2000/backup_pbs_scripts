#!/usr/bin/env bash

logs::init() {
    mkdir -p "${SCRIPT_DIR}/logs"
    local safe_name
    safe_name="$(sanitize_name "${BACKUP_NAME:-global}")"
    LOG_FILE="${SCRIPT_DIR}/logs/backup_${safe_name}.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

logs::log() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $*"
}

logs::info()  { logs::log "INFO"  "$*"; }
logs::error() { logs::log "ERROR" "$*"; }
logs::warn()  { logs::log "WARN"  "$*"; }
