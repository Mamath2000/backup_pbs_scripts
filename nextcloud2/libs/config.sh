#!/usr/bin/env bash

nextcloud::config::require_var() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        nextcloud::logs::error "Variable obligatoire absente dans la configuration: $name"
        exit 1
    fi
}

nextcloud::config::load() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        nextcloud::logs::error "Fichier de configuration introuvable: $CONFIG_FILE"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    nextcloud::tools::ensure_array CONF_PATHS
    nextcloud::tools::ensure_array CONF_SHARED_DATA_ROOTS
    nextcloud::tools::ensure_array USER_BACKUPS

    nextcloud::config::require_var DOCKER_CONTAINER_NAME
    nextcloud::config::require_var DB_USER
    nextcloud::config::require_var DB_NAME
    nextcloud::config::require_var WORK_BASE_DIR
    nextcloud::config::require_var NEXTCLOUD_VOLUME_NAME
    nextcloud::config::require_var NEXTCLOUD_CONFIG_PATH

    FILE_SUFFIX="${FILE_SUFFIX:-_nextcloud_backup.sql}"
    DUMP_BACKUP_NAME="${DUMP_BACKUP_NAME:-nextcloud-aio-dumps}"
    DUMP_DATASTORE="${DUMP_DATASTORE:-}"
    CONF_BACKUP_NAME="${CONF_BACKUP_NAME:-nextcloud-aio-config}"
    CONF_DATASTORE="${CONF_DATASTORE:-}"
    SHARED_DATA_DATASTORE="${SHARED_DATA_DATASTORE:-}"
    PBS_NAMESPACE="${PBS_NAMESPACE:-nextcloud}"
    USER_BACKUP_NAME_PREFIX="${USER_BACKUP_NAME_PREFIX:-nextcloud-aio-user}"

    if [[ ${#USER_BACKUPS[@]} -eq 0 ]]; then
        nextcloud::logs::error "USER_BACKUPS doit contenir au moins une entrée chemin|datastore"
        exit 1
    fi
}