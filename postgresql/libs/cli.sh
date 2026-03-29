#!/bin/bash

cli::parse() {
    local MODE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backup) MODE="backup"; shift ;;
            --check) MODE="check"; shift ;;
            --dummy-run) MODE="dummy-run"; shift ;;
            --help|-h) cli::usage; exit 0 ;;
            *) echo "Argument inconnu: $1"; cli::usage; exit 1 ;;
        esac
    done

    echo "$MODE"
}

cli::usage() {
    cat <<USAGE
Usage: $0 [--backup|--check|--dummy-run|--help]

--backup      : effectuer une sauvegarde (par défaut)
--check       : exécuter les vérifications / test PBS (skip lock)
--dummy-run   : exécuter en mode simulation (active TEST_MODE=true)
--help, -h    : afficher cette aide
USAGE
}
