
config::load() {
    local config_file="$1"
    local mode="$2"

    if [[ ! -f "$config_file" ]]; then
        echo "ERREUR: Fichier de configuration non trouvé: $config_file"
        [[ "$mode" != "check" ]] && rm -f "$LOCK_FILE"
        exit 1
    fi

    source "$config_file"
}
