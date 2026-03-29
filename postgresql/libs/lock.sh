lock::check() {
    local mode="$1"
    local lock_file="$2"

    [[ "$mode" == "check" ]] && return 0

    if [[ -f "$lock_file" ]]; then
        local pid
        pid=$(cat "$lock_file" 2>/dev/null)

        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "ERREUR: Une autre instance du script est déjà en cours (PID: $pid)"
            exit 1
        else
            echo "Suppression d'un verrou obsolète"
            rm -f "$lock_file"
        fi
    fi

    echo $$ > "$lock_file"
}

lock::cleanup() {
    local lock_file="$1"
    rm -f "$lock_file"
}
