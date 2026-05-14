nextcloud::runner::run_backup() {
    nextcloud::logs::info "=== Début de la sauvegarde Nextcloud simplifiée ==="
    nextcloud::logs::info "Base de données: $DB_NAME"

    nextcloud::docker::detect_running_container
    nextcloud::runtime::create_run_dirs
    nextcloud::docker::perform_database_dump
    nextcloud::jobs::build_conf_bundle

    nextcloud::jobs::run_cli_backup "$DUMP_BACKUP_NAME" "${WORK_RUN_DIR}/dumps" ""
    nextcloud::jobs::run_cli_backup "$CONF_BACKUP_NAME" "${WORK_RUN_DIR}/conf" ""
    nextcloud::jobs::run_shared_data_backups
    nextcloud::jobs::run_user_backups

    nextcloud::logs::info "Sauvegarde terminée avec succès"
    nextcloud::logs::info "Répertoire de travail: ${WORK_RUN_DIR}"
}