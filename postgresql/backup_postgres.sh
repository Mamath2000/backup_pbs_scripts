#!/bin/bash
#
# Script de sauvegarde PostgreSQL amélioré
# Fonctionnalités:
# - Sauvegarde distante via PBS<
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

# CLI parsing pour sélectionner le mode d'exécution
# Par défaut, aucun mode : afficher l'aide si aucun argument fourni
MODE=""
usage() {
    cat <<USAGE
Usage: $0 [--backup|--check|--dummy-run|--help]

--backup      : effectuer une sauvegarde (par défaut)
--check       : exécuter les vérifications / test PBS (skip lock)
--dummy-run   : exécuter en mode simulation (active TEST_MODE=true)
--help, -h    : afficher cette aide
USAGE
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup) MODE="backup"; shift ;;
        --check) MODE="check"; shift ;;
        --dummy-run) MODE="dummy-run"; shift ;;
        --help|-h) usage ;;
        *) echo "Argument inconnu: $1"; usage ;;
    esac
done

# Si aucun mode n'a été fourni, afficher l'aide (comportement par défaut)
if [[ -z "${MODE}" ]]; then
    usage
fi

# Fichier de verrou pour éviter les exécutions multiples (valeur par défaut dans SCRIPT_DIR)
LOCK_FILE="${LOCK_FILE:-${SCRIPT_DIR}/.backup_postgres.lock}"

# Vérification du verrou (sautée en mode check)
if [[ "${MODE}" != "check" ]]; then
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
fi

# Chargement de la configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERREUR: Fichier de configuration non trouvé: $CONFIG_FILE"
    [[ "${MODE}" != "check" ]] && rm -f "$LOCK_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# Après le sourcing: définir LOG_FILE par défaut et assurer le répertoire existe
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/logs/postgres_backup.log}"
mkdir -p "$(dirname "$LOG_FILE")"

# Authentification: on suppose l'utilisation de ~/.pgpass (le script n'expose pas de mot de passe)

# Si mode dummy-run demandé via CLI, activer TEST_MODE
if [[ "${MODE}" == "dummy-run" ]]; then
    TEST_MODE="true"
fi

# METADATA_DB: utilisé pour la publication de métriques et metadata PBS
METADATA_DB=""
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

# Support pour sauvegarder plusieurs bases.
# Si on est en mode perdb, BACKUP_TARGETS doit être défini (CSV). En mode cluster, on l'ignore.
if [[ "${BACKUP_MODE:-cluster}" == "perdb" ]]; then
    if [[ -n "${BACKUP_TARGETS:-}" ]]; then
        IFS=',' read -r -a TARGETS_ARRAY <<< "$BACKUP_TARGETS"
    else
        echo "BACKUP_TARGETS non défini dans la configuration. Définissez BACKUP_TARGETS=\"db1,db2\"" >&2
        [[ "${MODE}" != "check" ]] && rm -f "$LOCK_FILE" || true
        exit 1
    fi
else
    TARGETS_ARRAY=()
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
        if [[ "$BACKUP_STATUS" == "unknown" || "$BACKUP_STATUS" == "running" || "$BACKUP_STATUS" == "success" ]]; then
            BACKUP_STATUS="failed"
        fi
        if [[ -z "${ERROR_MESSAGE:-}" ]]; then
            ERROR_MESSAGE="Script interrompu avec le code d'erreur: $exit_code"
        fi
        
        [[ -f "$BACKUP_PATH" ]] && rm -f "$BACKUP_PATH"
        [[ -f "$COMPRESSED_PATH" ]] && rm -f "$COMPRESSED_PATH"
    fi
    
    BACKUP_DURATION=$(($(date +%s) - START_TIME))
    publish_metrics
    
    if [[ "${MODE}" != "check" ]]; then
        rm -f "$LOCK_FILE"
    fi
    
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
            }
        }
    }'
    
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        ${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASSWORD:+-P "$MQTT_PASSWORD"} \
        -t "$MQTT_DEVICE_TOPIC" -m "$device_config" -r 2>/dev/null || true
}

publish_metrics() {
    if [[ "$MQTT_ENABLED" != "true" ]]; then
        return 0
    fi
    
    log_debug "Publication des métriques MQTT unifiées"
    
    local current_timestamp=$(date -Iseconds)
    
    local unified_payload="{\n        \"status\": \"$BACKUP_STATUS\",\n        \"duration\": $BACKUP_DURATION,\n        \"size_mb\": $BACKUP_SIZE,\n        \"compression_ratio\": $COMPRESSION_RATIO,\n        \"backup_file\": \"$BACKUP_FILE_COMPRESSED\",\n        \"last_backup_timestamp\": \"$current_timestamp\",\n        \"error_message\": \"$ERROR_MESSAGE\",\n        \"backup_date\": \"$BACKUP_DATE\",\n        \"days_kept\": $DAYS_TO_KEEP,\n        \"pbs_enabled\": $( [ "${PBS_ENABLED:-false}" = "true" ] && echo "true" || echo "false" ),\n        \"pbs_ok\": $( [ "$PBS_OK" = "true" ] && echo "true" || echo "false" ),\n        \"pbs_status\": \"$PBS_STATUS\",\n        \"pbs_repository\": \"${PBS_REPOSITORY:-}\",\n        \"pbs_backup_id\": \"${PBS_BACKUP_ID:-}\",\n        \"database_name\": \"${METADATA_DB:-}\",\n        \"database_host\": \"$DB_HOST\",\n        \"test_mode\": $( [ "$TEST_MODE" = "true" ] && echo "true" || echo "false" ),\n        \"test_dummy_size_mb\": $TEST_DUMMY_SIZE_MB\n    }"
    
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

    local -a backup_specs=("$@")

    local repo_arg="${PBS_REPOSITORY}"
    if [[ -n "${PBS_DATASTORE:-}" && "$repo_arg" != *":"* ]]; then
        repo_arg="${repo_arg}:${PBS_DATASTORE}"
    fi

    log_info "Envoi vers PBS: repository='${repo_arg}', backup_id='${backup_id}', type='${backup_type}'"

    local -a pbs_args=("${pbs_client}" backup)
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
    "database": "${METADATA_DB:-}",
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

    mkdir -p "$staging_dir/meta" "$staging_dir/data"
    mv "$staging_dir/metadata.json" "$staging_dir/meta/metadata.json"

    mv "$staged_file" "$staging_dir/data/" || {
        log_error "Échec de déplacement du fichier vers staging/data"
        rm -rf "$staging_dir" || true
        return 1
    }

    # Génération dynamique de l'ID PBS: postgres-{db_name}
    local db_for_id="${DB_NAME:-${METADATA_DB:-cluster}}"
    local pbs_backup_id="postgres-${db_for_id}"
    # Sanitize: lowercase, espaces -> '-', caractères non alphanumériques remplacés par '-'
    pbs_backup_id=$(printf '%s' "$pbs_backup_id" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]\+/-/g' | sed 's/[^a-z0-9._-]/-/g')

    local old_pbs_backup_id="${PBS_BACKUP_ID:-}"
    PBS_BACKUP_ID="$pbs_backup_id"

    local meta_spec="${meta_archive_name}:${staging_dir}/meta"
    local data_spec="${archive_name}:${staging_dir}/data"

    log_info "Préparation PBS: meta_spec='${meta_spec}', data_spec='${data_spec}', backup_id='${PBS_BACKUP_ID}'"

    if pbs_run_backup "$meta_spec" "$data_spec"; then
        log_info "Envoi PBS réussi pour ${BACKUP_FILE} (backup_id=${PBS_BACKUP_ID})"
        PBS_OK="true"
        PBS_STATUS="ok"
        PBS_BACKUP_ID="${old_pbs_backup_id}"
        rm -rf "$staging_dir" || true
        return 0
    else
        log_error "Échec de l'envoi PBS"
        PBS_OK="false"
        PBS_STATUS="failed"
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
    fi

    log_info "Début de la sauvegarde de la base de données: $DB_NAME"

    local -a dump_cmd=(pg_dump --host "$DB_HOST" --port "$DB_PORT" -U "$DB_USER" "$DB_NAME" -f "$BACKUP_PATH" --format=t --blobs --create --clean --if-exists)

    log_debug "Commande de dump: ${dump_cmd[*]}"

    if "${dump_cmd[@]}" 2>>"$LOG_FILE"; then
        log_info "Dump de la base de données réussi"
        if [[ "$VERIFY_BACKUP" == "true" ]]; then
            verify_backup_integrity
        fi
        return 0
    else
        log_error "Échec du dump de la base de données"
        return 1
    fi
}

# Effectuer une sauvegarde complète du cluster avec pg_basebackup
perform_cluster_backup() {
    if [[ "$TEST_MODE" == "true" ]]; then
        log_info "MODE TEST: Création d'un fichier dummy de ${TEST_DUMMY_SIZE_MB}MB pour le cluster"
        create_dummy_backup
        return $?
    fi

    log_info "Début de la sauvegarde complète du cluster via pg_basebackup"
    # pg_basebackup ne peut pas envoyer les WAL vers stdout en mode tar.
    # Nous écrivons le backup dans un répertoire temporaire puis créons
    # une archive tar unique à partir de ce répertoire.

    local tmpdir
    tmpdir=$(mktemp -d -p "${BACKUP_DIR%/}" "pgbase.XXXXXX") || {
        log_error "Impossible de créer un répertoire temporaire pour pg_basebackup"
        return 1
    }

    log_debug "pg_basebackup -> répertoire temporaire: $tmpdir"

    if pg_basebackup -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -D "$tmpdir" -X stream --checkpoint=fast 2>>"$LOG_FILE"; then
        log_info "pg_basebackup écrit dans $tmpdir"
    else
        log_error "Échec de pg_basebackup (voir $LOG_FILE)"
        rm -rf "$tmpdir" || true
        return 1
    fi

    # Créer une archive tar à partir du répertoire temporaire
    log_debug "Création de l'archive tar: $BACKUP_PATH"
    if tar -C "$tmpdir" -cf "$BACKUP_PATH" . 2>>"$LOG_FILE"; then
        log_info "Archive créée: $BACKUP_PATH"
        rm -rf "$tmpdir" || true
        if [[ "$VERIFY_BACKUP" == "true" ]]; then
            verify_backup_integrity
        fi
        return 0
    else
        log_error "Échec de la création de l'archive tar (voir $LOG_FILE)"
        rm -rf "$tmpdir" || true
        return 1
    fi
}

create_dummy_backup() {
    log_debug "Création d'un fichier dummy de test"
    
    local size_bytes=$((TEST_DUMMY_SIZE_MB * 1024 * 1024))
    
    if dd if=/dev/urandom of="$BACKUP_PATH" bs=1M count="$TEST_DUMMY_SIZE_MB" 2>>"$LOG_FILE"; then
        log_info "Fichier dummy créé: $(basename "$BACKUP_PATH") (${TEST_DUMMY_SIZE_MB}MB)"
        
        {
            echo "# PostgreSQL Backup Test File"
            echo "# Created: $(date)"
            echo "# Size: ${TEST_DUMMY_SIZE_MB}MB"
            local display_db="${DB_NAME:-${METADATA_DB:-cluster}}"
            echo "# Database: ${display_db} (TEST MODE)"
            echo "# Host: $DB_HOST"
            echo "# This is a dummy file for testing purposes"
            echo "# Original data follows..."
        } > /tmp/test_header
        
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
        local expected_min_size=$((TEST_DUMMY_SIZE_MB * 1024 * 1024 / 2))
        
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
    publish_mqtt_discovery

    BACKUP_STATUS="running"
    PBS_STATUS=$([ "${PBS_ENABLED:-false}" = "true" ] && echo "pending" || echo "disabled")
    PBS_OK="false"
    publish_metrics

    create_backup_directory
    local overall_success=true

    if [[ "${TEST_MODE:-false}" == "true" ]]; then
        test_suffix="${TEST_FILE_SUFFIX:-_test}"
    else
        test_suffix=""
    fi

    case "${BACKUP_MODE:-cluster}" in
        cluster)
            log_info "--- Mode: cluster (pg_basebackup) ---"

            # Indiquer que c'est un backup cluster pour les métadonnées/metrics
            METADATA_DB="cluster"

            BACKUP_FILE="${BACKUP_DATE}_cluster${test_suffix}${FILE_SUFFIX}"
            BACKUP_PATH="${BACKUP_DIR}${BACKUP_FILE}"
            COMPRESSED_PATH="${BACKUP_PATH}.gz"
            BACKUP_FILE_COMPRESSED="${BACKUP_FILE}.gz"

            if perform_cluster_backup; then
                pbs_successful=true
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
                        log_info "Sauvegarde cluster terminée avec succès"
                    else
                        BACKUP_STATUS="failed"
                        ERROR_MESSAGE="Échec de l'envoi PBS"
                        log_error "Sauvegarde locale compressée OK mais envoi PBS en échec pour cluster"
                        overall_success=false
                    fi
                fi
            else
                BACKUP_STATUS="dump_failed"
                ERROR_MESSAGE="Échec de pg_basebackup"
                PBS_STATUS=$([ "${PBS_ENABLED:-false}" = "true" ] && echo "failed" || echo "disabled")
                PBS_OK="false"
                overall_success=false
            fi
            ;;

        perdb)
            log_info "--- Mode: perdb (pg_dump) ---"
            for target_db in "${TARGETS_ARRAY[@]}"; do
                log_info "Traitement de la base: $target_db"
            DB_NAME="$target_db"
            METADATA_DB="$DB_NAME"

                BACKUP_FILE="${BACKUP_DATE}_${DB_NAME}${test_suffix}${FILE_SUFFIX}"
                BACKUP_PATH="${BACKUP_DIR}${BACKUP_FILE}"
                COMPRESSED_PATH="${BACKUP_PATH}.gz"
                BACKUP_FILE_COMPRESSED="${BACKUP_FILE}.gz"

                if perform_database_dump; then
                    pbs_successful=true
                    if pbs_is_enabled; then
                        if ! pbs_backup_file "$BACKUP_PATH"; then
                            pbs_successful=false
                        fi
                    fi

                    if ! compress_backup; then
                        log_error "Échec de la compression pour $DB_NAME"
                        overall_success=false
                        BACKUP_STATUS="compression_failed"
                        ERROR_MESSAGE="Échec compression pour $DB_NAME"
                    else
                        cleanup_old_backups
                        if [[ "$pbs_successful" == true ]]; then
                            log_info "Sauvegarde de $DB_NAME terminée avec succès"
                        else
                            log_error "Sauvegarde locale OK mais envoi PBS en échec pour $DB_NAME"
                            overall_success=false
                            BACKUP_STATUS="failed"
                            ERROR_MESSAGE="Échec envoi PBS pour $DB_NAME"
                        fi
                    fi
                else
                    log_error "Échec du dump pour $DB_NAME"
                    overall_success=false
                    BACKUP_STATUS="dump_failed"
                    ERROR_MESSAGE="Échec dump pour $DB_NAME"
                fi
                # Mettre à jour l'état PBS global
                if [[ "${PBS_ENABLED:-false}" == "true" ]]; then
                    PBS_STATUS=$([[ "$pbs_successful" == true ]] && echo "ok" || echo "failed")
                    PBS_OK=$([[ "$pbs_successful" == true ]] && echo "true" || echo "false")
                else
                    PBS_STATUS="disabled"
                    PBS_OK="false"
                fi
            done
            if [[ "$overall_success" == true ]]; then
                BACKUP_STATUS="success"
            fi
            ;;

        *)
            log_error "Mode de backup inconnu: ${BACKUP_MODE}. Attendu 'cluster' ou 'perdb'"
            return 1
            ;;
    esac

    BACKUP_DURATION=$(($(date +%s) - START_TIME))
    publish_metrics

    if [[ "$overall_success" == true ]]; then
        log_info "=== Sauvegarde terminée avec succès ==="
    else
        log_error "=== Sauvegarde échouée ==="
        return 1
    fi

    log_info "Durée totale: ${BACKUP_DURATION}s"
    log_info "Taille finale: ${BACKUP_SIZE}MB"
    log_info "Ratio de compression: ${COMPRESSION_RATIO}%"
}

# ============================================================================
# VÉRIFICATIONS PRÉALABLES
# ============================================================================

check_dependencies() {
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

check_dependencies
check_config

touch "$LOG_FILE"

if [[ "${MODE}" == "check" ]]; then
    log_info "MODE=check: exécution de test_pbs_connection.sh"
    "${SCRIPT_DIR}/test_pbs_connection.sh" "$CONFIG_FILE"
    exit $?
fi

if [[ "${MODE}" == "dummy-run" ]]; then
    log_info "MODE=dummy-run: TEST_MODE activé"
    TEST_MODE="true"
fi

main

log_info "=== Script terminé ==="
