logs::log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}" | tee -a "$LOG_FILE"
}

logs::info() {
    logs::log "INFO" "$@"
}
logs::debug() {
    logs::log "DEBUG" "$@"
}

logs::warn() {
    logs::log "WARN" "$@"
}

logs::error() {
    logs::log "ERROR" "$@"
}

logs::init() {
    # Après le sourcing: définir LOG_FILE par défaut et assurer le répertoire existe
    LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/logs/postgres_backup.log}"
    mkdir -p "$(dirname "$LOG_FILE")"

    touch "$LOG_FILE"
    # Assurer permissions restreintes
    chmod 600 "$LOG_FILE" 2>/dev/null || true

    # Rotation basique par taille (LOG_MAX_SIZE_MB par défaut 10)
    local max_mb="${LOG_MAX_SIZE_MB:-10}"
    local max_bytes=$((max_mb * 1024 * 1024))
    local filesize
    filesize=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ $filesize -gt $max_bytes ]]; then
        local rotname="${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
        mv "$LOG_FILE" "$rotname" || true
        gzip -9 "$rotname" || true
        touch "$LOG_FILE"
        chmod 600 "$LOG_FILE" 2>/dev/null || true
    fi

    logs::info "=== Initialisation du logging ==="
    logs::debug "Fichier de log: $LOG_FILE"
}