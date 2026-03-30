#!/usr/bin/env bash

dump::create_backup_directory() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log::info "Création du répertoire de sauvegarde: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"
    fi
}

dump::perform_database_backup() {
    local database="$1"
    local backup_file="${BACKUP_DIR}${BACKUP_DATE}_${database}${FILE_SUFFIX}"
    
    log::info "Début de la sauvegarde de la base de données: $database"

    # Ajout du fichier à la liste pour le nettoyage
    BACKUP_FILES+=("$backup_file")

    if [[ "$TEST_MODE" == "true" ]]; then
        log::info "MODE TEST: Création d'un fichier dummy pour la base '$database'"
        dump::create_dummy_backup "$backup_file" "$database"
        local result=$?
        if [[ $result -eq 0 ]]; then
            # Tracker la taille du fichier
            local file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file")
            local file_size_mb=$(echo "scale=2; $file_size / 1024 / 1024" | bc)
            TOTAL_BACKUP_SIZE=$((TOTAL_BACKUP_SIZE + file_size))
            TOTAL_COMPRESSED_SIZE=$(echo "scale=2; $TOTAL_COMPRESSED_SIZE + $file_size_mb" | bc)
            log::debug "Taille du fichier dummy: ${file_size_mb}MB"
        fi
        return $result
    else
        # Commande de dump MariaDB (exécutée directement, sans /bin/bash -c)
        log::debug "Dump MariaDB pour la base: $database (user: $DB_USER)"

        if docker exec -i mariadb mariadb-dump -u"${DB_USER}" -p"${DB_PASSWORD}" --databases "${database}" --skip-comments --single-transaction --routines --triggers > "$backup_file"; then
            log::info "Dump de la base de données '$database' réussi"

            # Vérification systématique du dump SQL (pas de paramètre nécessaire)
            dump::verify_backup_integrity "$backup_file" || true

            # Tracker la taille du fichier
            local file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file")
            local file_size_mb=$(echo "scale=2; $file_size / 1024 / 1024" | bc)
            TOTAL_BACKUP_SIZE=$((TOTAL_BACKUP_SIZE + file_size))
            TOTAL_COMPRESSED_SIZE=$(echo "scale=2; $TOTAL_COMPRESSED_SIZE + $file_size_mb" | bc)
            log::debug "Taille du fichier: ${file_size_mb}MB"

            return 0
        else
            log::error "Échec du dump de la base de données '$database'"
            return 1
        fi
    fi
}

dump::create_dummy_backup() {
    local backup_file="$1"
    local database="$2"
    
    log::debug "Création d'un fichier dummy de test pour '$database'"

    # Création du fichier dummy avec dd
    if dd if=/dev/urandom of="$backup_file" bs=1M count="$DUMMY_FILE_SIZE_MB"; then
        log::info "Fichier dummy créé: $(basename "$backup_file") (${DUMMY_FILE_SIZE_MB}MB)"

        # Ajout d'un en-tête pour identifier le fichier comme étant un test
        {
            echo "-- MariaDB Backup Test File"
            echo "-- Created: $(date)"
            echo "-- Size: ${DUMMY_FILE_SIZE_MB}MB" 
            echo "-- Database: $database (TEST MODE)"
            echo "-- Container: $DOCKER_CONTAINER_NAME"
            echo "-- This is a dummy file for testing purposes"
            echo ""
            echo "CREATE DATABASE IF NOT EXISTS \`$database\`;"
            echo "USE \`$database\`;"
            echo ""
            echo "-- Original dummy data follows..."
        } > /tmp/test_header

        # Concaténation de l'en-tête avec le fichier dummy
        cat /tmp/test_header "$backup_file" > "${backup_file}.tmp" && mv "${backup_file}.tmp" "$backup_file"
        rm -f /tmp/test_header

        # Vérification systématique du dummy (pas de paramètre nécessaire)
        dump::verify_dummy_backup "$backup_file" || true

        return 0
    else
        log::error "Échec de la création du fichier dummy pour '$database'"
        return 1
    fi
}

dump::verify_dummy_backup() {
    local backup_file="$1"
    log::debug "Vérification du fichier dummy: $(basename "$backup_file")"

    if [[ -f "$backup_file" && -s "$backup_file" ]]; then
        local file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file")
        local expected_min_size=$((DUMMY_FILE_SIZE_MB * 1024 * 1024 / 2))  # Au moins 50% de la taille attendue

        if [[ $file_size -gt $expected_min_size ]]; then
            log::debug "Fichier dummy valide (taille: $file_size bytes)"
            return 0
        else
            log::error "Fichier dummy trop petit (taille: $file_size bytes, attendu: >$expected_min_size bytes)"
            return 1
        fi
    else
        log::error "Fichier dummy invalide ou vide"
        return 1
    fi
}

dump::verify_backup_integrity() {
    local backup_file="$1"
    log::debug "Vérification de l'intégrité de la sauvegarde: $(basename "$backup_file")"

    if [[ -f "$backup_file" && -s "$backup_file" ]]; then
        # Vérification basique du contenu SQL
        if grep -q "CREATE DATABASE" "$backup_file" && grep -q "USE " "$backup_file"; then
            log::debug "Fichier de sauvegarde valide"
            return 0
        else
            log::error "Fichier de sauvegarde invalide: contenu SQL incorrect"
            return 1
        fi
    else
        log::error "Fichier de sauvegarde invalide ou vide"
        return 1
    fi
}

dump::cleanup_old_backups() {
    local database="$1"
    
    log::info "Nettoyage des anciennes sauvegardes pour '$database' (conservation: ${DAYS_TO_KEEP} jours, max local: ${MAX_LOCAL_BACKUPS})"

    # Nettoyage par âge
    local deleted_count=0
    while IFS= read -r -d '' file; do
        log::debug "Suppression de l'ancienne sauvegarde: $(basename "$file")"
        rm -f "$file"
        deleted_count=$((deleted_count + 1))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -mtime +$DAYS_TO_KEEP -name "*${database}${FILE_SUFFIX}" -print0 2>/dev/null)

    # Nettoyage par nombre (garder seulement les N plus récents)
    local backup_count=$(find "$BACKUP_DIR" -maxdepth 1 -name "*${database}${FILE_SUFFIX}" 2>/dev/null | wc -l)
    if [[ $backup_count -gt $MAX_LOCAL_BACKUPS ]]; then
        local to_delete=$((backup_count - MAX_LOCAL_BACKUPS))
        log::info "Suppression de $to_delete sauvegarde(s) pour respecter la limite de $MAX_LOCAL_BACKUPS"
        
        find "$BACKUP_DIR" -maxdepth 1 -name "*${database}${FILE_SUFFIX}" -type f -printf '%T@ %p\n' 2>/dev/null | \
        sort -n | head -n "$to_delete" | cut -d' ' -f2- | \
        while IFS= read -r file; do
            log::debug "Suppression pour limite de nombre: $(basename "$file")"
            rm -f "$file"
            deleted_count=$((deleted_count + 1))
        done
    fi

    log::info "Suppression de $deleted_count ancienne(s) sauvegarde(s) pour '$database'"
}
