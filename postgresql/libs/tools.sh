tools::check_dependencies() {
    local missing_deps=()
    
    for tool in bc; do
        if ! command -v "$tool" &> /dev/null; then
            missing_deps+=("$tool")
        fi
    done

    # Dépendances selon le mode de backup
    if [[ "${BACKUP_MODE:-cluster}" == "cluster" ]]; then
        if ! command -v pg_basebackup &> /dev/null; then
            missing_deps+=("postgresql-base (pg_basebackup)")
        fi
    else
        if ! command -v pg_dump &> /dev/null; then
            missing_deps+=("postgresql-client (pg_dump)")
        fi
    fi

    if ! command -v jq >/dev/null 2>&1; then
        missing_deps+=("jq")
    fi

    if [[ "$MQTT_ENABLED" == "true" ]] && ! command -v mosquitto_pub &> /dev/null; then
        missing_deps+=("mosquitto-clients")
    fi
    
    if [[ "${PBS_ENABLED:-false}" == "true" ]]; then
        if ! command -v "${PBS_CLIENT:-proxmox-backup-client}" &> /dev/null; then
            missing_deps+=("proxmox-backup-client")
        fi
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        logs::error "Dépendances manquantes: ${missing_deps[*]}"
        exit 1
    fi


}

tools::check_config() {
    if [[ "$MQTT_ENABLED" == "true" ]]; then
        if [[ -z "$MQTT_HOST" ]]; then
            logs::error "MQTT_HOST non défini pour Home Assistant"
            exit 1
        fi
    fi

    if [[ "${PBS_ENABLED:-false}" == "true" ]]; then
        if [[ -z "${PBS_REPOSITORY:-}" ]]; then
            logs::error "PBS_REPOSITORY non défini dans la configuration"
            exit 1
        fi
    fi

    # Interdire l'utilisation de DB_PASSWORD dans la configuration :
    # n'autoriser QUE l'authentification via ~/.pgpass (PGPASSFILE).
    if [[ -n "${DB_PASSWORD:-}" ]]; then
        echo "ERREUR: DB_PASSWORD est défini dans la configuration. Le script n'autorise PAS les mots de passe en clair. Utilisez ~/.pgpass (PGPASSFILE) pour l'authentification PostgreSQL." >&2
        [[ "${MODE}" != "check" ]] && lock::cleanup "$LOCK_FILE" || true
        exit 1
    fi
    # Authentification: on suppose l'utilisation de ~/.pgpass (le script n'expose pas de mot de passe)

    # Si mode dummy-run demandé via CLI, activer TEST_MODE
    if [[ "${MODE}" == "dummy-run" ]]; then
        TEST_MODE="true"
    fi

    # Support pour sauvegarder plusieurs bases.
    # Si on est en mode perdb, BACKUP_TARGETS doit être défini (CSV). En mode cluster, on l'ignore.
    if [[ "${BACKUP_MODE:-cluster}" == "perdb" ]]; then
        if [[ -n "${BACKUP_TARGETS:-}" ]]; then
            IFS=',' read -r -a TARGETS_ARRAY <<< "$BACKUP_TARGETS"
        else
            echo "BACKUP_TARGETS non défini dans la configuration. Définissez BACKUP_TARGETS=\"db1,db2\"" >&2
            [[ "${MODE}" != "check" ]] && lock::cleanup "$LOCK_FILE" || true
            exit 1
        fi
    else
        TARGETS_ARRAY=()
    fi

}
