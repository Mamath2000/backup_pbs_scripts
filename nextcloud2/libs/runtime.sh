#!/usr/bin/env bash

nextcloud::runtime::cleanup() {
    local exit_code=$?
    trap - EXIT

    if [[ "$LOCK_ACQUIRED" == "true" ]]; then
        rm -f "$LOCK_FILE"
    fi

    if [[ $exit_code -ne 0 ]]; then
        nextcloud::logs::error "Script interrompu avec le code d'erreur: $exit_code"
        if [[ -n "$WORK_RUN_DIR" && -d "$WORK_RUN_DIR" ]]; then
            nextcloud::logs::error "Répertoire de travail conservé pour diagnostic: $WORK_RUN_DIR"
        fi
    fi

    exit $exit_code
}

nextcloud::runtime::check_dependencies() {
    local missing=()

    for tool in docker; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if [[ ! -x "$CLI_BACKUP_SCRIPT" ]]; then
        missing+=("cli/backup_pbs.sh")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        nextcloud::logs::error "Dépendances manquantes: ${missing[*]}"
        exit 1
    fi
}

nextcloud::runtime::acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            nextcloud::logs::error "Une autre instance est déjà en cours (PID: $lock_pid)"
            exit 1
        fi
        rm -f "$LOCK_FILE"
    fi

    echo $$ > "$LOCK_FILE"
    LOCK_ACQUIRED=true
}

nextcloud::runtime::create_run_dirs() {
    RUN_TIMESTAMP="$(date '+%Y%m%d%H%M%S')"
    WORK_RUN_DIR="${WORK_BASE_DIR%/}/${RUN_TIMESTAMP}"
    mkdir -p "$WORK_RUN_DIR/dumps" "$WORK_RUN_DIR/conf/generated" "$WORK_RUN_DIR/conf/files"
}