#!/usr/bin/env bash

nextcloud::cli::usage() {
    cat <<EOF
Usage: $(basename "$0") --backup [--config FICHIER]
       $(basename "$0") --check
       $(basename "$0") --help

Le script prépare les artefacts locaux Nextcloud puis délègue tous les backups PBS à cli/backup_pbs.sh.
EOF
}

nextcloud::cli::parse() {
    if [[ $# -eq 0 ]]; then
        nextcloud::cli::usage
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backup)
                MODE="backup"
                ;;
            --check)
                MODE="check"
                ;;
            --config)
                shift
                CONFIG_FILE="${1:-}"
                ;;
            --help|-h)
                nextcloud::cli::usage
                exit 0
                ;;
            *)
                echo "ERREUR: Argument inconnu: $1" >&2
                nextcloud::cli::usage
                exit 1
                ;;
        esac
        shift
    done

    if [[ -z "$MODE" ]]; then
        nextcloud::cli::usage
        exit 1
    fi

    if [[ "$MODE" == "backup" && -z "$CONFIG_FILE" ]]; then
        echo "ERREUR: Fichier de configuration invalide" >&2
        exit 1
    fi
}