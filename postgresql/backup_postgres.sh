#!/bin/bash
#
# Script de sauvegarde PostgreSQL amélioré
# Fonctionnalités:
# - Sauvegarde distante via PBS
# - Publication de métriques vers Home Assistant via MQTT
# - Gestion d'erreurs robuste
# - Logging détaillé
# - Configuration centralisée
#

set -euo pipefail

# Répertoire du script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Permet d'override le fichier de config via variable d'environnement CONFIG_FILE
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/backup_postgres.conf}"

# Fichier de verrou pour éviter les exécutions multiples
LOCK_FILE="/var/run/postgres_backup.lock"

# Vérification du verrou
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "ERREUR: Une autre instance du script est déjà en cours (PID: $LOCK_PID)"
        exit 1
    else
        echo "Suppression d'un verrou obsolète"
        rm -f "$LOCK_FILE"
    fi
fi

# Création du verrou
echo $$ > "$LOCK_FILE"

# Chargement de la configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERREUR: Fichier de configuration non trouvé: $CONFIG_FILE"
    rm -f "$LOCK_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# Variables globales
START_TIME=$(date +%s)
BACKUP_DATE=$(date +"%Y%m%d%H%M")

# Suffixe à ajouter aux fichiers en mode test (modifiable dans la conf)
TEST_FILE_SUFFIX="${TEST_FILE_SUFFIX:-_test}"

# Détermination du nom de fichier initial (utilisé pour les métriques préalables)
if [[ "${TEST_MODE:-false}" == "true" ]]; then
    BACKUP_FILE="${BACKUP_DATE}${TEST_FILE_SUFFIX}${FILE_SUFFIX}"
else
    BACKUP_FILE="${BACKUP_DATE}${FILE_SUFFIX}"
fi

BACKUP_PATH="${BACKUP_DIR}${BACKUP_FILE}"
COMPRESSED_PATH="${BACKUP_PATH}.gz"
BACKUP_FILE_COMPRESSED="${BACKUP_FILE}.gz"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

# Statistiques de la sauvegarde
BACKUP_STATUS="unknown"
BACKUP_DURATION=0
BACKUP_SIZE=0
COMPRESSION_RATIO=0
ERROR_MESSAGE=""
PBS_STATUS="unknown"
PBS_OK="false"

# Support pour sauvegarder plusieurs bases (par défaut la base configurée)
# Si vous voulez aussi sauvegarder la base 'ltss', mettez BACKUP_LTSS=true dans la conf
BACKUP_TARGETS=("$DB_NAME")
BACKUP_LTSS="${BACKUP_LTSS:-false}"
LTSS_DB_NAME="${LTSS_DB_NAME:-ltss}"
if [[ "$BACKUP_LTSS" == "true" ]]; then
    BACKUP_TARGETS+=("$LTSS_DB_NAME")
fi

# Assurer une valeur par défaut pour le suffixe de test si non fournie
TEST_FILE_SUFFIX="${TEST_FILE_SUFFIX:-_test}"

# Activer/désactiver la compression (true|false)
COMPRESSION_ENABLED="${COMPRESSION_ENABLED:-true}"

# ============================================================================
# FONCTIONS UTILITAIRES
# ============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() {
    log "INFO" "$@"
}

log_warn() {
    log "WARN" "$@"
}

log_error() {
    log "ERROR" "$@"
}

log_debug() {
    [[ "$LOG_LEVEL" == "DEBUG" ]] && log "DEBUG" "$@" || true
}

# Fonction de nettoyage en cas d'erreur
cleanup() {
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script interrompu avec le code d'erreur: $exit_code"
        # Ne pas écraser un statut plus précis (dump_failed, etc.)
        if [[ "$BACKUP_STATUS" == "unknown" || "$BACKUP_STATUS" == "running" || "$BACKUP_STATUS" == "success" ]]; then
            BACKUP_STATUS="failed"
        fi
        if [[ -z "${ERROR_MESSAGE:-}" ]]; then
            ERROR_MESSAGE="Script interrompu avec le code d'erreur: $exit_code"
        fi
        
        # Nettoyage des fichiers temporaires
        [[ -f "$BACKUP_PATH" ]] && rm -f "$BACKUP_PATH"
        [[ -f "$COMPRESSED_PATH" ]] && rm -f "$COMPRESSED_PATH"
    fi
    
    # Calcul de la durée finale
    BACKUP_DURATION=$(($(date +%s) - START_TIME))
    
    # Publication des métriques finales
    publish_metrics
    
    # Suppression du verrou
    rm -f "$LOCK_FILE"
    
    exit $exit_code
}

trap cleanup EXIT

# ============================================================================
# FONCTIONS MQTT / HOME ASSISTANT
# ============================================================================

publish_mqtt_discovery() {
    if [[ "$MQTT_ENABLED" != "true" ]]; then
        return 0
    fi
    
    log_debug "Publication de la déclaration de device MQTT"
    
    # Configuration du device avec tous les composants
    local device_config='{
        "device": {
            "identifiers": ["postgres_backup_monitor"],
            "name": "PostgreSQL Backup Monitor",
            "model": "PostgreSQL Backup Script",
            "manufacturer": "Custom Script",
            "sw_version": "2.0.0"
        },
        "origin": {
            "name": "PostgreSQL Backup Script"
        },
        "state_topic": "'$MQTT_STATE_TOPIC'",
        "components": {
            "status": {
                "platform": "sensor",
                "unique_id": "postgres_backup_status",
                "default_entity_id": "sensor.postgres_backup_status",
                "has_entity_name": true,
                "force_update": true,
                "name": "Status",
                "icon": "mdi:database-check",
                "value_template": "{{ value_json.status }}",
                "device_class": null,
                "state_class": null
            },
            "duration": {
                "platform": "sensor",
                "unique_id": "postgres_backup_duration",
                "default_entity_id": "sensor.postgres_backup_duration",
                "has_entity_name": true,
                "force_update": true,
                "name": "Duration",
                "icon": "mdi:timer-outline",
                "value_template": "{{ value_json.duration }}",
                "device_class": "duration",
                "unit_of_measurement": "s",
                "state_class": "measurement"
            },
            "size": {
                "platform": "sensor",
                "unique_id": "postgres_backup_size",
                "default_entity_id": "sensor.postgres_backup_size",
                "has_entity_name": true,
                "force_update": true,
                "name": "Backup Size",
                "icon": "mdi:file-document-outline",
                "value_template": "{{ value_json.size_mb }}",
                "device_class": "data_size",
                "unit_of_measurement": "MB",
                "state_class": "measurement"
            },
            "compression": {
                "platform": "sensor",
                "unique_id": "postgres_backup_compression",
                "default_entity_id": "sensor.postgres_backup_compression",
                "has_entity_name": true,
                "force_update": true,
                "name": "Compression Ratio",
                "icon": "mdi:archive",
                "value_template": "{{ value_json.compression_ratio }}",
                "device_class": null,
                "unit_of_measurement": "%",
                "state_class": "measurement"
            },
            "last_run": {
                "platform": "sensor",
                "unique_id": "postgres_backup_last_run",
                "default_entity_id": "sensor.postgres_backup_last_run",
                "has_entity_name": true,
                "force_update": true,
                "name": "Last Backup",
                "icon": "mdi:clock-outline",
                "value_template": "{{ as_datetime(value_json.last_backup_timestamp) }}",
                "device_class": "timestamp"
            },
            "problem": {
                "platform": "binary_sensor",
                "unique_id": "postgres_backup_problem",
                "default_entity_id": "binary_sensor.postgres_backup_problem",
                "has_entity_name": true,
                "force_update": true,
                "name": "Backup Problem",
                "icon": "mdi:alert-circle",
                "value_template": "{{ \"failed\" if value_json.status in [\"failed\", \"dump_failed\"] else \"success\" }}",
                "device_class": "problem",
                "payload_on": "failed",
                "payload_off": "success"
            },
            "pbs_status": {
                "platform": "binary_sensor",
                "unique_id": "postgres_backup_pbs_status",
                "default_entity_id": "binary_sensor.postgres_backup_pbs_status",
                "has_entity_name": true,
                "force_update": true,
                "name": "PBS Backup OK",
                "icon": "mdi:cloud-check",
                "value_template": "{{ value_json.pbs_ok }}",
                "device_class": "problem",
                "payload_on": false,
                "payload_off": true
            }
        }
    }'
    
    # Publication de la configuration du device
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        ${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASSWORD:+-P "$MQTT_PASSWORD"} \
        -t "$MQTT_DEVICE_TOPIC" -m "$device_config" -r 2>/dev/null || true
}

publish_metrics() {
    if [[ "$MQTT_ENABLED" != "true" ]]; then
        return 0
    fi
    
    log_debug "Publication des métriques MQTT unifiées"
    
    # Calcul du timestamp ISO8601
    local current_timestamp=$(date -Iseconds)
    
    # Création du payload JSON unifié avec toutes les métriques
    local unified_payload="{
        \"status\": \"$BACKUP_STATUS\",
        \"duration\": $BACKUP_DURATION,
        \"size_mb\": $BACKUP_SIZE,
        \"compression_ratio\": $COMPRESSION_RATIO,
        \"backup_file\": \"$BACKUP_FILE_COMPRESSED\",
        \"last_backup_timestamp\": \"$current_timestamp\",
        \"error_message\": \"$ERROR_MESSAGE\",
        \"backup_date\": \"$BACKUP_DATE\",
        \"days_kept\": $DAYS_TO_KEEP,
        \"pbs_enabled\": $([ "${PBS_ENABLED:-false}" = "true" ] && echo "true" || echo "false"),
        \"pbs_ok\": $([ "$PBS_OK" = "true" ] && echo "true" || echo "false"),
        \"pbs_status\": \"$PBS_STATUS\",
        \"pbs_repository\": \"${PBS_REPOSITORY:-}\",
        \"pbs_backup_id\": \"${PBS_BACKUP_ID:-}\",
        \"database_name\": \"$DB_NAME\",
        \"database_host\": \"$DB_HOST\",
        \"test_mode\": $([ "$TEST_MODE" = "true" ] && echo "true" || echo "false"),
        \"test_dummy_size_mb\": $TEST_DUMMY_SIZE_MB
    }"
    
    # Publication du payload unifié sur le topic unique
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        ${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASSWORD:+-P "$MQTT_PASSWORD"} \
        -t "$MQTT_STATE_TOPIC" -m "$unified_payload" -r 2>/dev/null || true
        
    log_debug "Métriques publiées sur: $MQTT_STATE_TOPIC"
}

# =========================================================================
# FONCTIONS PBS
# =========================================================================

pbs_is_enabled() {
    [[ "${PBS_ENABLED:-false}" == "true" ]]
}

pbs_run_backup() {
    local -a backup_specs=()
    local backup_id="${PBS_BACKUP_ID:-postgres}"
    local backup_type="host"
    local pbs_namespace="${PBS_NAMESPACE:-}"
    local pbs_client="${PBS_CLIENT:-proxmox-backup-client}"


    if [[ -z "${PBS_REPOSITORY:-}" ]]; then
        log_error "PBS_REPOSITORY non défini"
        return 1
    fi

    # Récupérer correctement tous les arguments de spécification
    local -a backup_specs=("$@")

    # Construire l'argument --repository en ajoutant PBS_DATASTORE si fourni
    local repo_arg="${PBS_REPOSITORY}"
    if [[ -n "${PBS_DATASTORE:-}" && "$repo_arg" != *":"* ]]; then
        repo_arg="${repo_arg}:${PBS_DATASTORE}"
    fi

    log_info "Envoi vers PBS: repository='${repo_arg}', backup_id='${backup_id}', type='${backup_type}'"

    local -a pbs_args=("${pbs_client}" backup)
    # ajouter les spécifications d'archive
    for spec in "${backup_specs[@]}"; do
        pbs_args+=("$spec")
    done

    pbs_args+=(--backup-id "$backup_id" --backup-type "$backup_type")
    if [[ -n "$pbs_namespace" ]]; then
        pbs_args+=(--ns "$pbs_namespace")
    fi
    pbs_args+=(--repository "$repo_arg")

    local -a env_args=("PBS_REPOSITORY=${repo_arg}")
    [[ -n "${PBS_PASSWORD:-}" ]] && env_args+=("PBS_PASSWORD=${PBS_PASSWORD}")
    [[ -n "${PBS_FINGERPRINT:-}" ]] && env_args+=("PBS_FINGERPRINT=${PBS_FINGERPRINT}")

    log_debug "DEBUG PBS env: ${env_args[*]}"
    log_debug "DEBUG PBS cmd: ${pbs_args[*]}"

    if env "${env_args[@]}" "${pbs_args[@]}" >>"$LOG_FILE" 2>&1; then
        return 0
    fi

    return 1
}

pbs_backup_file() {
    local file_path="$1"

    if ! pbs_is_enabled; then
        log_info "PBS désactivé, transfert ignoré"
        return 0
    fi

    if [[ ! -f "$file_path" ]]; then
        log_error "Fichier introuvable pour PBS: $file_path"
        return 1
    fi

    local staging_dir
    staging_dir=$(mktemp -d -p "${BACKUP_DIR%/}" ".pbs-staging.${BACKUP_DATE}.XXXXXX")

    cat >"$staging_dir/metadata.json" <<EOF
{
  "backup_date": "${BACKUP_DATE}",
  "database": "${DB_NAME}",
  "database_host": "${DB_HOST}",
  "file": "${BACKUP_FILE}"
}

EOF

    local staged_file="$staging_dir/$BACKUP_FILE"
    if ! ln "$file_path" "$staged_file" 2>/dev/null; then
        log_warn "Impossible de créer un lien dur, copie du fichier pour PBS"
        if ! cp -a "$file_path" "$staged_file"; then
            log_error "Échec de préparation du fichier pour PBS"
            rm -rf "$staging_dir" || true
            return 1
        fi
    fi

    local archive_prefix="${PBS_ARCHIVE_PREFIX:-postgres}"
    local archive_name="${archive_prefix}.pxar"
    local meta_archive_name="${PBS_METADATA_ARCHIVE_NAME:-metadata.pxar}"

    # Préparer les sous-répertoires attendus par proxmox-backup-client
    mkdir -p "$staging_dir/meta" "$staging_dir/data"
    # déplacer metadata.json dans meta
    mv "$staging_dir/metadata.json" "$staging_dir/meta/metadata.json"

    # placer le fichier de sauvegarde dans data
    mv "$staged_file" "$staging_dir/data/" || {
        log_error "Échec de déplacement du fichier vers staging/data"
        rm -rf "$staging_dir" || true
        return 1
    }

    # Choisir l'ID PBS en fonction de la base: utiliser un ID dédié pour ltss si fourni
    local pbs_backup_id="${PBS_BACKUP_ID:-postgres}"
    if [[ "${DB_NAME}" == "${LTSS_DB_NAME:-ltss}" && -n "${PBS_BACKUP_ID_LTSS:-}" ]]; then
        pbs_backup_id="${PBS_BACKUP_ID_LTSS}"
    fi

    # Sauvegarder la valeur précédente et la remplacer temporairement
    local old_pbs_backup_id="${PBS_BACKUP_ID:-}"
    PBS_BACKUP_ID="$pbs_backup_id"

    # Construire les backupspecs: <archive_name>:<source_dir>
    local meta_spec="${meta_archive_name}:${staging_dir}/meta"
    local data_spec="${archive_name}:${staging_dir}/data"

    log_info "Préparation PBS: meta_spec='${meta_spec}', data_spec='${data_spec}', backup_id='${PBS_BACKUP_ID}'"

    # Appel de l'envoi vers PBS
    if pbs_run_backup "$meta_spec" "$data_spec"; then
        log_info "Envoi PBS réussi pour ${BACKUP_FILE} (backup_id=${PBS_BACKUP_ID})"
        PBS_OK="true"
        PBS_STATUS="ok"
        # restaurer l'ID précédent
        PBS_BACKUP_ID="${old_pbs_backup_id}"
        rm -rf "$staging_dir" || true
        return 0
    else
        log_error "Échec de l'envoi PBS"
        PBS_OK="false"
        PBS_STATUS="failed"
        # restaurer l'ID précédent
        PBS_BACKUP_ID="${old_pbs_backup_id}"
        rm -rf "$staging_dir" || true
        return 1
    fi
}

# ============================================================================
# FONCTIONS DE SAUVEGARDE
# ============================================================================

create_backup_directory() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_info "Création du répertoire de sauvegarde: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"
    fi
}

perform_database_dump() {
    if [[ "$TEST_MODE" == "true" ]]; then
        log_info "MODE TEST: Création d'un fichier dummy de ${TEST_DUMMY_SIZE_MB}MB"
        create_dummy_backup
        return $?
    else
        log_info "Début de la sauvegarde de la base de données: $DB_NAME"
        
        local dump_cmd="pg_dump --host $DB_HOST --port $DB_PORT -U $DB_USER $DB_NAME -f $BACKUP_PATH --no-password --format=t --blobs --create --clean --if-exists"
        
        log_debug "Commande de dump: $dump_cmd"
        
        if PGPASSWORD="$DB_PASSWORD" $dump_cmd 2>>"$LOG_FILE"; then
            log_info "Dump de la base de données réussi"
            
            if [[ "$VERIFY_BACKUP" == "true" ]]; then
                verify_backup_integrity
            fi
            
            return 0
        else
            log_error "Échec du dump de la base de données"
            return 1
        fi
    fi
}

create_dummy_backup() {
    log_debug "Création d'un fichier dummy de test"
    
    # Calcul de la taille en bytes (MB * 1024 * 1024)
    local size_bytes=$((TEST_DUMMY_SIZE_MB * 1024 * 1024))
    
    # Création du fichier dummy avec dd
    if dd if=/dev/urandom of="$BACKUP_PATH" bs=1M count="$TEST_DUMMY_SIZE_MB" 2>>"$LOG_FILE"; then
        log_info "Fichier dummy créé: $(basename "$BACKUP_PATH") (${TEST_DUMMY_SIZE_MB}MB)"
        
        # Ajout d'un en-tête pour identifier le fichier comme étant un test
        {
            echo "# PostgreSQL Backup Test File"
            echo "# Created: $(date)"
            echo "# Size: ${TEST_DUMMY_SIZE_MB}MB"
            echo "# Database: $DB_NAME (TEST MODE)"
            echo "# Host: $DB_HOST"
            echo "# This is a dummy file for testing purposes"
            echo "# Original data follows..."
        } > /tmp/test_header
        
        # Concaténation de l'en-tête avec le fichier dummy
        cat /tmp/test_header "$BACKUP_PATH" > "${BACKUP_PATH}.tmp" && mv "${BACKUP_PATH}.tmp" "$BACKUP_PATH"
        rm -f /tmp/test_header
        
        if [[ "$VERIFY_BACKUP" == "true" ]]; then
            verify_dummy_backup
        fi
        
        return 0
    else
        log_error "Échec de la création du fichier dummy"
        return 1
    fi
}

verify_dummy_backup() {
    log_debug "Vérification du fichier dummy"
    
    if [[ -f "$BACKUP_PATH" && -s "$BACKUP_PATH" ]]; then
        local file_size=$(stat -c%s "$BACKUP_PATH" 2>/dev/null || stat -f%z "$BACKUP_PATH")
        local expected_min_size=$((TEST_DUMMY_SIZE_MB * 1024 * 1024 / 2))  # Au moins 50% de la taille attendue
        
        if [[ $file_size -gt $expected_min_size ]]; then
            log_debug "Fichier dummy valide (taille: $file_size bytes)"
            return 0
        else
            log_error "Fichier dummy trop petit (taille: $file_size bytes, attendu: >$expected_min_size bytes)"
            return 1
        fi
    else
        log_error "Fichier dummy invalide ou vide"
        return 1
    fi
}

verify_backup_integrity() {
    log_debug "Vérification de l'intégrité de la sauvegarde"
    
    if [[ -f "$BACKUP_PATH" && -s "$BACKUP_PATH" ]]; then
        log_debug "Fichier de sauvegarde valide"
        return 0
    else
        log_error "Fichier de sauvegarde invalide ou vide"
        return 1
    fi
}

compress_backup() {
    if [[ "${COMPRESSION_ENABLED:-true}" != "true" ]]; then
        log_info "Compression désactivée; conservation du fichier non compressé"
        BACKUP_FILE_COMPRESSED="${BACKUP_FILE}"
        COMPRESSED_PATH="${BACKUP_PATH}"
        local size_bytes
        size_bytes=$(stat -f%z "$BACKUP_PATH" 2>/dev/null || stat -c%s "$BACKUP_PATH")
        BACKUP_SIZE=$(echo "scale=2; $size_bytes / 1024 / 1024" | bc)
        COMPRESSION_RATIO=0
        return 0
    fi

    log_info "Compression locale de la sauvegarde"

    local original_size
    original_size=$(stat -f%z "$BACKUP_PATH" 2>/dev/null || stat -c%s "$BACKUP_PATH")

    if gzip -"${COMPRESSION_LEVEL:-6}" "$BACKUP_PATH"; then
        local compressed_size
        compressed_size=$(stat -f%z "$COMPRESSED_PATH" 2>/dev/null || stat -c%s "$COMPRESSED_PATH")

        COMPRESSION_RATIO=$(( (original_size - compressed_size) * 100 / original_size ))
        BACKUP_SIZE=$(echo "scale=2; $compressed_size / 1024 / 1024" | bc)

        log_info "Compression locale réussie. Taille originale: ${original_size} bytes, compressée: ${compressed_size} bytes (${COMPRESSION_RATIO}%)"
        return 0
    else
        log_error "Échec de la compression locale"
        return 1
    fi
}

cleanup_old_backups() {
    log_info "Nettoyage des anciennes sauvegardes (conservation: ${DAYS_TO_KEEP} jours)"
    
    local deleted_count=0
    while IFS= read -r -d '' file; do
        log_debug "Suppression de l'ancienne sauvegarde: $(basename "$file")"
        rm -f "$file"
        deleted_count=$((deleted_count + 1))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -mtime +$DAYS_TO_KEEP \( -name "*${FILE_SUFFIX}.gz" -o -name "*${FILE_SUFFIX}" \) -print0)
    log_info "Suppression de $deleted_count ancienne(s) sauvegarde(s)"
}

# ============================================================================
# FONCTION PRINCIPALE
# ============================================================================

main() {
    log_info "=== Début de la sauvegarde PostgreSQL ==="
    log_info "Fichier de sauvegarde: $BACKUP_FILE"
    
    # Publication de la découverte MQTT au début
    publish_mqtt_discovery
    
    # Initialisation du statut
    BACKUP_STATUS="running"
    PBS_STATUS=$([ "${PBS_ENABLED:-false}" = "true" ] && echo "pending" || echo "disabled")
    PBS_OK="false"
    publish_metrics
    
    # Étapes de la sauvegarde pour chaque base ciblée
    create_backup_directory

    local overall_success=true
    for target_db in "${BACKUP_TARGETS[@]}"; do
        log_info "--- Sauvegarde de la base: ${target_db} ---"

        # Préparer les variables spécifiques à la base
        DB_NAME="${target_db}"
        if [[ "${TEST_MODE:-false}" == "true" ]]; then
            local test_suffix="${TEST_FILE_SUFFIX:-_test}"
        else
            local test_suffix=""
        fi

        BACKUP_FILE="${BACKUP_DATE}_${DB_NAME}${test_suffix}${FILE_SUFFIX}"
        BACKUP_PATH="${BACKUP_DIR}${BACKUP_FILE}"
        COMPRESSED_PATH="${BACKUP_PATH}.gz"
        BACKUP_FILE_COMPRESSED="${BACKUP_FILE}.gz"

        BACKUP_STATUS="running"
        PBS_STATUS=$([ "${PBS_ENABLED:-false}" = "true" ] && echo "pending" || echo "disabled")
        PBS_OK="false"
        publish_metrics

        if perform_database_dump; then
            local pbs_successful=true
            if pbs_is_enabled; then
                if ! pbs_backup_file "$BACKUP_PATH"; then
                    pbs_successful=false
                fi
            fi

            if [[ "${PBS_ENABLED:-false}" == "true" ]]; then
                PBS_STATUS=$([[ "$pbs_successful" == true ]] && echo "ok" || echo "failed")
                PBS_OK=$([[ "$pbs_successful" == true ]] && echo "true" || echo "false")
            else
                PBS_STATUS="disabled"
                PBS_OK="false"
            fi

            if ! compress_backup; then
                BACKUP_STATUS="compression_failed"
                ERROR_MESSAGE="Échec de la compression locale"
                overall_success=false
            else
                cleanup_old_backups
                if [[ "$pbs_successful" == true ]]; then
                    BACKUP_STATUS="success"
                    log_info "Sauvegarde de ${DB_NAME} terminée avec succès"
                else
                    BACKUP_STATUS="failed"
                    ERROR_MESSAGE="Échec de l'envoi PBS"
                    log_error "Sauvegarde locale compressée OK mais envoi PBS en échec pour ${DB_NAME}"
                    overall_success=false
                fi
            fi
        else
            BACKUP_STATUS="dump_failed"
            ERROR_MESSAGE="Échec du dump de la base de données ${DB_NAME}"
            PBS_STATUS=$([ "${PBS_ENABLED:-false}" = "true" ] && echo "failed" || echo "disabled")
            PBS_OK="false"
            overall_success=false
        fi

        # Publier métriques pour cette base
        BACKUP_DURATION=$(($(date +%s) - START_TIME))
        publish_metrics
    done

    if [[ "$overall_success" == true ]]; then
        log_info "=== Toutes les sauvegardes terminées avec succès ==="
        BACKUP_STATUS="success"
    else
        log_error "=== Au moins une sauvegarde a échoué ==="
        BACKUP_STATUS="failed"
        return 1
    fi
    
    # Calcul de la durée finale
    BACKUP_DURATION=$(($(date +%s) - START_TIME))
    
    log_info "Durée totale: ${BACKUP_DURATION}s"
    log_info "Taille finale: ${BACKUP_SIZE}MB"
    log_info "Ratio de compression: ${COMPRESSION_RATIO}%"
}

# ============================================================================
# VÉRIFICATIONS PRÉALABLES
# ============================================================================

check_dependencies() {
    local missing_deps=()
    
    # Vérification des outils requis
    for tool in pg_dump bc; do
        if ! command -v "$tool" &> /dev/null; then
            missing_deps+=("$tool")
        fi
    done
    
    # Vérification des outils optionnels
    if [[ "$MQTT_ENABLED" == "true" ]] && ! command -v mosquitto_pub &> /dev/null; then
        missing_deps+=("mosquitto-clients")
    fi
    
    if [[ "${PBS_ENABLED:-false}" == "true" ]]; then
        if ! command -v "${PBS_CLIENT:-proxmox-backup-client}" &> /dev/null; then
            missing_deps+=("proxmox-backup-client")
        fi
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Dépendances manquantes: ${missing_deps[*]}"
        exit 1
    fi
}

check_config() {
    if [[ "$MQTT_ENABLED" == "true" ]]; then
        if [[ -z "$MQTT_HOST" ]]; then
            log_error "MQTT_HOST non défini pour Home Assistant"
            exit 1
        fi
    fi

    if [[ "${PBS_ENABLED:-false}" == "true" ]]; then
        if [[ -z "${PBS_REPOSITORY:-}" ]]; then
            log_error "PBS_REPOSITORY non défini dans la configuration"
            exit 1
        fi
    fi
}

# ============================================================================
# POINT D'ENTRÉE
# ============================================================================

# Vérifications initiales
check_dependencies
check_config

# Création du fichier de log si nécessaire
touch "$LOG_FILE"

# Exécution principale
main

log_info "=== Script terminé ==="