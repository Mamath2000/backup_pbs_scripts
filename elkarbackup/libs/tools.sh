#!/usr/bin/env bash

tools::check_dependencies() {
    local missing_deps=()

    # Vérification des outils requis
    for tool in docker bc; do
        if ! command -v "$tool" &> /dev/null; then
            missing_deps+=("$tool")
        fi
    done

    # Vérification des outils optionnels
    if [[ "$MQTT_ENABLED" == "true" ]] && ! command -v mosquitto_pub &> /dev/null; then
        missing_deps+=("mosquitto-clients")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log::error "Dépendances manquantes: ${missing_deps[*]}"
        exit 1
    fi
}


# Normalise un nom pour en faire un nom d'archive sûr
tools::sanitize_name() {
    echo "$1" | tr -c '[:alnum:]_-' '_' | sed 's/_\+/_/g' | sed 's/^_//;s/_$//'
}

# Fonction d'affichage du temps
tools::displaytime() {
    local T=$1
    local D=$((T/60/60/24))
    local H=$((T/60/60%24))
    local M=$((T/60%60))
    local S=$((T%60))
    (( $D > 0 )) && printf '%d days ' $D
    (( $H > 0 )) && printf '%d hours ' $H
    (( $M > 0 )) && printf '%d minutes ' $M
    (( $T < 60 )) && printf '< 1 minutes'
}

# Fonction de calcul de taille en MB
tools::get_size_mb() {
    local f=$1
    if [[ -f "$f" ]]; then
        local size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
        local tsize=$(echo "scale=2; $size / 1024 / 1024" | bc)
        if [[ ${tsize:0:1} == "." ]]; then tsize="0$tsize"; fi
        printf '%s' $tsize
    else
        printf '0'
    fi
}

# Fonction de calcul de taille en GB
tools::get_size_gb() {
    local f=$1
    if [[ -f "$f" ]]; then
        local size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
        local tsize=$(echo "scale=2; $size / 1024 / 1024 / 1024" | bc)
        if [[ ${tsize:0:1} == "." ]]; then tsize="0$tsize"; fi
        printf '%s' $tsize
    else
        printf '0'
    fi
}

tools::install_trap() {
    # Accept optional MODE and LOCK_FILE arguments (backwards-compatible)
    if [[ -n "${1:-}" ]]; then MODE="$1"; fi
    if [[ -n "${2:-}" ]]; then LOCK_FILE="$2"; fi
    trap tools::cleanup_run EXIT
}

# Fonction de nettoyage en cas d'erreur
tools::cleanup_run() {
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log::error "Script interrompu avec le code d'erreur: $exit_code"
        BACKUP_STATUS="failed"
        ERROR_MESSAGE="Script interrompu avec le code d'erreur: $exit_code"

        # Nettoyage des fichiers temporaires
        for backup_file in "${BACKUP_FILES[@]}"; do
            [[ -f "$backup_file" ]] && rm -f "$backup_file"
            [[ -f "${backup_file}.gz" ]] && rm -f "${backup_file}.gz"
        done
    fi

    # Calcul de la durée finale
    BACKUP_DURATION=$(($(date +%s) - START_TIME))

    # Publication des métriques finales (sauf en mode check)
    [[ "$MODE" != "check" ]] && mqtt::publish_metrics

    # Suppression du verrou
    [[ "$MODE" != "check" ]] && rm -f "$LOCK_FILE"

    exit $exit_code
}

# Backwards-compatible wrapper: displaytime -> tools::displaytime
displaytime() { tools::displaytime "$@"; }
