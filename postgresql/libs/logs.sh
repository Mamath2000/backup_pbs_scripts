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
    logs::info "=== Initialisation du logging ==="
    logs::debug "Fichier de log: $LOG_FILE"
}