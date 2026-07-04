#!/usr/bin/env bash

nextcloud::tools::require_directory() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        nextcloud::logs::error "Répertoire introuvable: $path"
        return 1
    fi
}

nextcloud::tools::ensure_array() {
    local name="$1"
    if ! declare -p "$name" >/dev/null 2>&1; then
        eval "$name=()"
    fi
}

nextcloud::tools::resolve_path() {
    local path="$1"

    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s\n' "${SCRIPT_DIR}/$path"
    fi
}

nextcloud::tools::sanitize_component() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g'
}