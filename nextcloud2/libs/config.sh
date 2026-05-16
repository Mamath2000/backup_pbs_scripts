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
    nextcloud::tools::ensure_array DATA_ROOT_INCLUDE_DIRS
    nextcloud::tools::ensure_array USER_BACKUPS

    nextcloud::config::require_var DOCKER_CONTAINER_NAME
    nextcloud::config::require_var DB_USER
    nextcloud::config::require_var DB_NAME
    nextcloud::config::require_var WORK_BASE_DIR
    nextcloud::config::require_var NEXTCLOUD_VOLUME_NAME
    nextcloud::config::require_var NEXTCLOUD_CONFIG_PATH
    nextcloud::config::require_var NEXTCLOUD_DATA_ROOT

    FILE_SUFFIX="${FILE_SUFFIX:-_nextcloud_backup.sql}"
    MAX_DUMP_ARCHIVES="${MAX_DUMP_ARCHIVES:-5}"
    CONFIG_DATASTORE="${CONFIG_DATASTORE:-}"
    PBS_NAMESPACE="${PBS_NAMESPACE:-nextcloud}"
    USER_BACKUP_NAME_PREFIX="${USER_BACKUP_NAME_PREFIX:-nextcloud-aio-user}"

    if [[ ${#DATA_ROOT_INCLUDE_DIRS[@]} -eq 0 ]]; then
        DATA_ROOT_INCLUDE_DIRS=(
            "admin"
            "appdata_*"
        )
    fi
}