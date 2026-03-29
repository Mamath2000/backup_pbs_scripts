#!/usr/bin/env bash

cli::usage() {
    cat <<EOF
Usage:
  $(basename "$0") "nom-backup" -d /chemin/unique [-e /chemin/exclu]... [--datastore NAME]
  $(basename "$0") --check [--datastore NAME] [--namespace NAME]
EOF
}

cli::parse() {
    MODE="backup"
    BACKUP_NAME=""
    BACKUP_DIR=""
    EXCLUDES=()
    PBS_DATASTORE_ARG=""
    PBS_NAMESPACE_ARG=""

    if [[ "${1:-}" == "--check" ]]; then
        MODE="check"
        shift
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --datastore) shift; PBS_DATASTORE_ARG="${1:-}";;
                --namespace|--ns) shift; PBS_NAMESPACE_ARG="${1:-}";;
                -h|--help) cli::usage; exit 0;;
                *) logs::error "Argument inconnu pour --check : $1"; exit 1;;
            esac
            shift
        done
        return
    fi

    if [[ $# -lt 2 ]]; then
        cli::usage
        exit 1
    fi

    BACKUP_NAME="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d) shift; BACKUP_DIR="${1:-}";;
            -e) shift; EXCLUDES+=("${1:-}");;
            --datastore) shift; PBS_DATASTORE_ARG="${1:-}";;
            -h|--help) cli::usage; exit 0;;
            *) logs::error "Argument inconnu : $1"; cli::usage; exit 1;;
        esac
        shift
    done

    if [[ -z "$BACKUP_DIR" ]]; then
        logs::error "Aucun répertoire à sauvegarder (-d) fourni."
        cli::usage
        exit 1
    fi
    if [[ ! -d "$BACKUP_DIR" ]]; then
        logs::error "Répertoire à sauvegarder introuvable : $BACKUP_DIR"
        exit 1
    fi
}
