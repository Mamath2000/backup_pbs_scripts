
config::load() {
    local config_file="$1"
    local mode="$2"

    if [[ ! -f "$config_file" ]]; then
        echo "ERREUR: Fichier de configuration non trouvé: $config_file"
        [[ "$mode" != "check" ]] && rm -f "$LOCK_FILE"
        exit 1
    fi

    # Vérifier que le fichier de configuration est en 600 (permissions restreintes)
    local perms
    perms=$(stat -c %a "$config_file" 2>/dev/null || stat -f %Lp "$config_file" 2>/dev/null || echo "")
    if [[ "$perms" != "600" ]]; then
        echo "ERREUR: Permissions du fichier de configuration incorrectes: $config_file ($perms). Attendu: 600" >&2
        [[ "$mode" != "check" ]] && rm -f "$LOCK_FILE" || true
        exit 1
    fi

    source "$config_file"
}
