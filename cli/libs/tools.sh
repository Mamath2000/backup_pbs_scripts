#!/usr/bin/env bash

require_var() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        logs::error "Variable requise manquante: $name"
        exit 1
    fi
}

sanitize_name() {
    echo "$1" | tr -c '[:alnum:]_-' '_' | sed 's/_\+/_/g' | sed 's/^_//;s/_$//'
}
