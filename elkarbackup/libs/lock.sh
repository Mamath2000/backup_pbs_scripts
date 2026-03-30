#!/usr/bin/env bash

lock::check() {
    local mode="$1"
    local dir="$2"
    LOCK_FILE="$dir/.backup_elkarbackup.lock"

    [[ "$mode" == "check" ]] && return 0

    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "ERREUR: Une autre instance du script est déjà en cours (PID: $pid)"
            exit 1
        else
            echo "Suppression d'un verrou obsolète"
            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE"
}
