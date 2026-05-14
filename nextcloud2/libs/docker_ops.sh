#!/usr/bin/env bash

nextcloud::docker::detect_running_container() {
    DOCKER_ID="$(docker ps --no-trunc -qf name="$DOCKER_CONTAINER_NAME" | head -n1)"
    if [[ -n "$DOCKER_ID" ]]; then
        return 0
    fi

    local stopped_id
    stopped_id="$(docker ps --no-trunc -aqf name="$DOCKER_CONTAINER_NAME" | head -n1)"
    if [[ -n "$stopped_id" ]]; then
        nextcloud::logs::error "Conteneur Docker '$DOCKER_CONTAINER_NAME' trouvé mais non démarré"
    else
        nextcloud::logs::error "Conteneur Docker '$DOCKER_CONTAINER_NAME' non trouvé"
    fi
    exit 1
}

nextcloud::docker::perform_database_dump() {
    local dump_file="${WORK_RUN_DIR}/dumps/${RUN_TIMESTAMP}${FILE_SUFFIX}"
    local dump_tmp="${dump_file}.tmp"

    nextcloud::logs::info "Début du dump de la base de données: $DB_NAME"

    rm -f "$dump_tmp"

    if ! docker exec "$DOCKER_ID" pg_dump -U "$DB_USER" "$DB_NAME" -F p > "$dump_tmp"; then
        rm -f "$dump_tmp"
        nextcloud::logs::error "Échec du dump de la base de données '$DB_NAME'"
        return 1
    fi

    if [[ ! -s "$dump_tmp" ]]; then
        rm -f "$dump_tmp"
        nextcloud::logs::error "Dump PostgreSQL vide pour '$DB_NAME'"
        return 1
    fi

    mv "$dump_tmp" "$dump_file"
    nextcloud::logs::info "Dump créé: $dump_file"
}

nextcloud::docker::export_config_php() {
    local output_file="${WORK_RUN_DIR}/conf/generated/config.php"

    nextcloud::logs::info "Export du fichier config.php depuis le volume Nextcloud"
    if ! docker run --rm \
        --volume "${NEXTCLOUD_VOLUME_NAME}:/var/www/html:ro" \
        alpine sh -lc "cat '${NEXTCLOUD_CONFIG_PATH}'" > "$output_file"; then
        nextcloud::logs::error "Échec de l'export de config.php"
        return 1
    fi

    if [[ ! -s "$output_file" ]]; then
        nextcloud::logs::error "config.php exporté mais vide"
        return 1
    fi

    nextcloud::logs::info "config.php exporté vers: $output_file"
}