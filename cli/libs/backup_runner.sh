#!/usr/bin/env bash

backup::run() {
    START_TIME=$(date +%s)
    BACKUP_STATUS="running"
    ERROR_MESSAGE=""
    BACKUP_DATE=$(date +"%Y%m%d%H%M")

    PBS_BACKUP_ID="${PBS_BACKUP_ID:-$BACKUP_NAME}"

    mqtt::publish_discovery

    EXTRA_ARGS=()
    [[ -n "${PBS_CHANGE_DETECTION_MODE:-}" ]] && EXTRA_ARGS+=(--change-detection-mode "$PBS_CHANGE_DETECTION_MODE")
    if [[ -n "${PBS_CLIENT_EXTRA_ARGS:-}" ]]; then
        read -r -a extra_user_args <<< "$PBS_CLIENT_EXTRA_ARGS"
        EXTRA_ARGS+=("${extra_user_args[@]}")
    fi
    for ex in "${EXCLUDES[@]}"; do
        EXTRA_ARGS+=(--exclude "$ex")
    done

    pbs::build_repository_full
    pbs::build_specs

    trap backup::cleanup EXIT

    logs::info "Démarrage backup: name='${BACKUP_NAME}', mode='${PBS_CLIENT_MODE}'"
    pbs::run_backup

    BACKUP_STATUS="success"
    logs::info "Backup terminé avec succès"
}

backup::cleanup() {
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        BACKUP_STATUS="failed"
        ERROR_MESSAGE="Script interrompu avec le code d'erreur: $exit_code"
    fi

    BACKUP_DURATION=$(( $(date +%s) - START_TIME ))
    mqtt::publish_metrics
    exit $exit_code
}
