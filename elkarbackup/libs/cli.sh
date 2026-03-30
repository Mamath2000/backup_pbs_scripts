#!/usr/bin/env bash

cli::usage() {
    cat << EOF
Usage: $(basename "$0") [OPTION]

Options:
  --backup      Mode normal de sauvegarde
  --check       Vérifier la connexion PBS uniquement
  --dummy-run   Mode test avec fichiers dummy (sans vraie sauvegarde)
  --help, -h    Afficher cette aide

Si aucune option n'est spécifiée, cette aide sera affichée.

EOF
    exit 0
}

cli::parse() {
    MODE=""
    PBS_DATASTORE_ARG=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backup) MODE="backup" ;;
            --check) MODE="check" ;;
            --dummy-run) MODE="dummy-run" ;;
            --datastore)
                shift
                PBS_DATASTORE_ARG="${1:-}"
                [[ -z "$PBS_DATASTORE_ARG" ]] && echo "Erreur: --datastore requiert un nom" && exit 1
                ;;
            --help|-h) cli::usage ;;
            *)
                echo "Erreur: Argument inconnu '$1'"
                cli::usage
                ;;
        esac
        shift
    done

    [[ -z "$MODE" ]] && cli::usage
}
