runner::run_generic() {
    local mode="$1"          # cluster | perdb
    local dbname="$2"        # "" ou nom DB
    local dump_function="$3" # nom de la fonction à appeler

    METADATA_DB="$dbname"
    # Assurer que les fonctions attendent `DB_NAME` même si vide (évite set -u erreurs)
    DB_NAME="$dbname"

    # Calculer l’ID PBS
    pbs::compute_backup_id "$mode" "$dbname"

    # Préparer les chemins
    backup::prepare_paths

    # MQTT discovery (utiliser 'cluster' comme display_name si dbname vide)
    local display_name
    display_name="${dbname:-cluster}"
    mqtt::init_backup "$PBS_BACKUP_ID" "$display_name"

    # Statut initial
    BACKUP_STATUS="running"
    PBS_STATUS=$([[ "${PBS_ENABLED:-false}" == "true" ]] && echo "pending" || echo "disabled")
    PBS_OK="false"
    mqtt::publish_metrics "$PBS_BACKUP_ID"

    # Mesure du temps
    local start_ts
    start_ts=$(date +%s)

    # Exécution du dump (passer le nom de la base au dump function)
    if "$dump_function" "$dbname"; then
        local pbs_successful=true

        # Envoi PBS (pbs::run_backup gère pbs::backup_file internement)
        if pbs::is_enabled; then
            if ! pbs::run_backup "$BACKUP_PATH"; then
                pbs_successful=false
                ERROR_MESSAGE="Échec envoi PBS"
            fi
        else
            pbs_successful=false
        fi

        # Compression
        if ! backup::compress; then
            BACKUP_STATUS="compression_failed"
            ERROR_MESSAGE="Échec compression"
        else
            backup::cleanup_old
            if [[ "$pbs_successful" == true ]]; then
                BACKUP_STATUS="success"
            else
                # Si PBS désactivé, on considère la sauvegarde locale comme OK
                if [[ "${PBS_ENABLED:-false}" == "true" ]]; then
                    BACKUP_STATUS="failed"
                else
                    BACKUP_STATUS="success"
                fi
            fi
        fi
    else
        BACKUP_STATUS="dump_failed"
        ERROR_MESSAGE="Échec dump"
    fi

    # Durée
    BACKUP_DURATION=$(( $(date +%s) - start_ts ))

    # MQTT final
    mqtt::publish_metrics "$PBS_BACKUP_ID"

    [[ "$BACKUP_STATUS" == "success" ]]
}

