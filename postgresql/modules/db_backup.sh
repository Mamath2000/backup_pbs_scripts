#!/bin/bash

backup::create_directory() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        logs::info "Création du répertoire de sauvegarde: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"
    fi
}

backup::prepare_paths() {
    BACKUP_FILE="${BACKUP_DATE}_${PBS_BACKUP_ID}.tar"
    BACKUP_PATH="${BACKUP_DIR}${BACKUP_FILE}"
    COMPRESSED_PATH="${BACKUP_PATH}.gz"
    BACKUP_FILE_COMPRESSED="${BACKUP_FILE}.gz"
}

backup::perform_database_dump() {
    local db_arg="${1:-}"
    if [[ -n "$db_arg" ]]; then
        DB_NAME="$db_arg"
    fi

    if [[ "${TEST_MODE:-false}" == "true" ]]; then
        logs::info "MODE TEST: Création d'un fichier dummy de ${TEST_DUMMY_SIZE_MB}MB"
        backup::create_dummy
        return $?
    fi

    logs::info "Début de la sauvegarde de la base de données: ${DB_NAME}"

    local -a dump_cmd=(pg_dump --host "$DB_HOST" --port "$DB_PORT" -U "$DB_USER" "$DB_NAME" -f "$BACKUP_PATH" --format=t --blobs --create --clean --if-exists)

    logs::debug "Commande de dump: ${dump_cmd[*]}"

    if "${dump_cmd[@]}" 2>>"$LOG_FILE"; then
        logs::info "Dump de la base de données réussi"
        if [[ "${VERIFY_BACKUP:-false}" == "true" ]]; then
            backup::verify_integrity
        fi
        return 0
    else
        logs::error "Échec du dump de la base de données"
        return 1
    fi
}

# Effectuer une sauvegarde complète du cluster avec pg_basebackup
backup::perform_cluster_dump() {
    if [[ "${TEST_MODE:-false}" == "true" ]]; then
        logs::info "MODE TEST: Création d'un fichier dummy de ${TEST_DUMMY_SIZE_MB}MB pour le cluster"
        backup::create_dummy
        return $?
    fi

    logs::info "Début de la sauvegarde complète du cluster via pg_basebackup"

    local tmpdir
    tmpdir=$(mktemp -d -p "${BACKUP_DIR%/}" "pgbase.XXXXXX") || {
        logs::error "Impossible de créer un répertoire temporaire pour pg_basebackup"
        return 1
    }

    logs::debug "pg_basebackup -> répertoire temporaire: $tmpdir"

    if pg_basebackup -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -D "$tmpdir" -X stream --checkpoint=fast 2>>"$LOG_FILE"; then
        logs::info "pg_basebackup écrit dans $tmpdir"
    else
        logs::error "Échec de pg_basebackup (voir $LOG_FILE)"
        rm -rf "$tmpdir" || true
        return 1
    fi

    logs::debug "Création de l'archive tar: $BACKUP_PATH"
    if tar -C "$tmpdir" -cf "$BACKUP_PATH" . 2>>"$LOG_FILE"; then
        logs::info "Archive créée: $BACKUP_PATH"
        rm -rf "$tmpdir" || true
        if [[ "${VERIFY_BACKUP:-false}" == "true" ]]; then
            backup::verify_integrity
        fi
        return 0
    else
        logs::error "Échec de la création de l'archive tar (voir $LOG_FILE)"
        rm -rf "$tmpdir" || true
        return 1
    fi
}

backup::create_dummy() {
    logs::debug "Création d'un fichier dummy de test"

    if dd if=/dev/urandom of="$BACKUP_PATH" bs=1M count="$TEST_DUMMY_SIZE_MB" 2>>"$LOG_FILE"; then
        logs::info "Fichier dummy créé: $(basename "$BACKUP_PATH") (${TEST_DUMMY_SIZE_MB}MB)"

        local header_file
        header_file=$(mktemp -p "${BACKUP_DIR%/}" ".dummy_header.XXXXXX")
        {
            echo "# PostgreSQL Backup Test File"
            echo "# Created: $(date)"
            echo "# Size: ${TEST_DUMMY_SIZE_MB}MB"
            local display_db="${DB_NAME:-${METADATA_DB:-cluster}}"
            echo "# Database: ${display_db} (TEST MODE)"
            echo "# Host: $DB_HOST"
            echo "# This is a dummy file for testing purposes"
            echo "# Original data follows..."
        } > "$header_file"

        cat "$header_file" "$BACKUP_PATH" > "${BACKUP_PATH}.tmp" && mv "${BACKUP_PATH}.tmp" "$BACKUP_PATH"
        rm -f "$header_file"

        if [[ "${VERIFY_BACKUP:-false}" == "true" ]]; then
            backup::verify_dummy
        fi

        return 0
    else
        logs::error "Échec de la création du fichier dummy"
        return 1
    fi
}

backup::verify_dummy() {
    logs::debug "Vérification du fichier dummy"

    if [[ -f "$BACKUP_PATH" && -s "$BACKUP_PATH" ]]; then
        local file_size
        file_size=$(stat -c%s "$BACKUP_PATH" 2>/dev/null || stat -f%z "$BACKUP_PATH")
        local expected_min_size=$((TEST_DUMMY_SIZE_MB * 1024 * 1024 / 2))

        if [[ $file_size -gt $expected_min_size ]]; then
            logs::debug "Fichier dummy valide (taille: $file_size bytes)"
            return 0
        else
            logs::error "Fichier dummy trop petit (taille: $file_size bytes, attendu: >$expected_min_size bytes)"
            return 1
        fi
    else
        logs::error "Fichier dummy invalide ou vide"
        return 1
    fi
}

backup::verify_integrity() {
    logs::debug "Vérification de l'intégrité de la sauvegarde"

    if [[ -f "$BACKUP_PATH" && -s "$BACKUP_PATH" ]]; then
        logs::debug "Fichier de sauvegarde valide"
        return 0
    else
        logs::error "Fichier de sauvegarde invalide ou vide"
        return 1
    fi
}

backup::compress() {
    if [[ "${COMPRESSION_ENABLED:-true}" != "true" ]]; then
        logs::info "Compression désactivée; conservation du fichier non compressé"
        BACKUP_FILE_COMPRESSED="${BACKUP_FILE}"
        COMPRESSED_PATH="${BACKUP_PATH}"
        local size_bytes
        size_bytes=$(stat -f%z "$BACKUP_PATH" 2>/dev/null || stat -c%s "$BACKUP_PATH")
        BACKUP_SIZE=$(echo "scale=2; $size_bytes / 1024 / 1024" | bc)
        COMPRESSION_RATIO=0
        return 0
    fi

    logs::info "Compression locale de la sauvegarde"

    local original_size
    original_size=$(stat -f%z "$BACKUP_PATH" 2>/dev/null || stat -c%s "$BACKUP_PATH")

    if gzip -"${COMPRESSION_LEVEL:-6}" "$BACKUP_PATH"; then
        local compressed_size
        compressed_size=$(stat -f%z "$COMPRESSED_PATH" 2>/dev/null || stat -c%s "$COMPRESSED_PATH")

        COMPRESSION_RATIO=$(( (original_size - compressed_size) * 100 / original_size ))
        BACKUP_SIZE=$(echo "scale=2; $compressed_size / 1024 / 1024" | bc)

        logs::info "Compression locale réussie. Taille originale: ${original_size} bytes, compressée: ${compressed_size} bytes (${COMPRESSION_RATIO}%)"
        return 0
    else
        logs::error "Échec de la compression locale"
        return 1
    fi
}

backup::cleanup_old() {
    logs::info "Nettoyage des anciennes sauvegardes (conservation: ${DAYS_TO_KEEP} jours)"

    local deleted_count=0
    while IFS= read -r -d '' file; do
        logs::debug "Suppression de l'ancienne sauvegarde: $(basename "$file")"
        rm -f "$file"
        deleted_count=$((deleted_count + 1))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -mtime +$DAYS_TO_KEEP \( -name "*.tar.gz" -o -name "*.tar" \) -print0)
    logs::info "Suppression de $deleted_count ancienne(s) sauvegarde(s)"
}
