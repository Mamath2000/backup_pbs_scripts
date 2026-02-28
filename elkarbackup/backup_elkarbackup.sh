#!/bin/bash
#
# Script de sauvegarde MariaDB (ElkarBackup) amélioré
# Fonctionnalités:
# - Envoi vers Proxmox Backup Server (PBS)
# - Publication de métriques vers Home Assistant via MQTT
# - Gestion d'erreurs robuste
# - Logging détaillé
# - Configuration centralisée
# - Sauvegarde locale limitée + distant PBS
#
# Usage:
#   ./backup_elkarbackup.sh [--backup|--check|--dummy-run|--help]
#   --backup    : Mode normal de sauvegarde
#   --check     : Vérifie uniquement la connexion PBS
#   --dummy-run : Mode test avec fichiers dummy
#   --help      : Affiche l'aide (par défaut si aucun argument)
#

set -euo pipefail

# Répertoire du script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup_elkarbackup.conf"

# Mode d'exécution (backup, check, dummy-run, help)
MODE=""

# Gestion des arguments
show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTION]

Options:
  --backup      Mode normal de sauvegarde
  --check       Vérifier la connexion PBS uniquement
  --dummy-run   Mode test avec fichiers dummy (sans vraie sauvegarde)
  --help, -h    Afficher cette aide

Si aucune option n'est spécifiée, cette aide sera affichée.

EOF
    exit 0
}


# Ajout gestion du datastore
PBS_DATASTORE="${PBS_DATASTORE_DEFAULT:-}" # datastore par défaut
if [[ -z "$PBS_DATASTORE" ]]; then
    PBS_DATASTORE="backup" # fallback si non défini
fi
PBS_DATASTORE_ARG=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --backup)
            MODE="backup"
            shift
            ;;
        --check)
            MODE="check"
            shift
            ;;
        --dummy-run)
            MODE="dummy-run"
            shift
            ;;
        --datastore)
            shift
            if [[ -z "${1:-}" ]]; then
                echo "Erreur: --datastore requiert un nom de datastore"
                exit 1
            fi
            PBS_DATASTORE_ARG="$1"
            shift
            ;;
        --help|-h)
            show_usage
            ;;
        *)
            echo "Erreur: Argument inconnu '$1'"
            echo "Utilisez --help pour voir les options disponibles"
            exit 1
            ;;
    esac
done

# Si aucun argument fourni, afficher l'aide
if [[ -z "$MODE" ]]; then
    show_usage
fi

# Fichier de verrou pour éviter les exécutions multiples
LOCK_FILE="/var/run/backup_elkarbackup.lock"

# Vérification du verrou (non nécessaire en mode check)
if [[ "$MODE" != "check" ]]; then
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
    [[ "$MODE" != "check" ]] && rm -f "$LOCK_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# Construction de la chaîne PBS_REPOSITORY complète avec le datastore
PBS_DATASTORE="${PBS_DATASTORE_DEFAULT:-backup}"
if [[ -n "$PBS_DATASTORE_ARG" ]]; then
    PBS_REPOSITORY_FULL="$PBS_REPOSITORY:$PBS_DATASTORE_ARG"
else
    PBS_REPOSITORY_FULL="$PBS_REPOSITORY:$PBS_DATASTORE"
fi
# Mode client PBS par défaut (docker ou apt)
PBS_CLIENT_MODE="${PBS_CLIENT_MODE:-docker}"
# Défaut du fichier de log si non défini dans la conf
LOG_FILE="${LOG_FILE:-/var/log/elkarbackup_backup.log}"
# MQTT topics: construits en dur dans le script (alignés sur CLI)
# Pas besoin de définir `MQTT_DEVICE_TOPIC`/`MQTT_STATE_TOPIC` dans la conf.
MQTT_DEVICE_TOPIC="homeassistant/device/backup/${PBS_BACKUP_ID}/config"
MQTT_STATE_TOPIC="backup/${PBS_BACKUP_ID}/state"
# Variables locales pour le mode test
TEST_MODE=false
DUMMY_FILE_SIZE_MB=50

# Si mode dummy-run, activer le TEST_MODE
if [[ "$MODE" == "dummy-run" ]]; then
    TEST_MODE=true
fi

# Variables globales
START_TIME=$(date +%s)
BACKUP_DATE=$(date +"%Y%m%d%H%M")

# Statistiques de la sauvegarde
BACKUP_STATUS="unknown"
BACKUP_DURATION=0
TOTAL_BACKUP_SIZE=0
TOTAL_COMPRESSED_SIZE=0
COMPRESSION_RATIO=0
ERROR_MESSAGE=""
BACKUP_FILES=()

# Obtenir l'ID du conteneur Docker (sauf en mode check)
DOCKER_ID=""
if [[ "$MODE" != "check" ]]; then
    DOCKER_ID=$(docker ps --no-trunc -aqf name="$DOCKER_CONTAINER_NAME")

    if [[ -z "$DOCKER_ID" ]]; then
        echo "ERREUR: Conteneur Docker '$DOCKER_CONTAINER_NAME' non trouvé"
        rm -f "$LOCK_FILE"
        exit 1
    fi
fi
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

# Normalise un nom pour en faire un nom d'archive sûr
sanitize_name() {
    echo "$1" | tr -c '[:alnum:]_-' '_' | sed 's/_\+/_/g' | sed 's/^_//;s/_$//'
}

# Fonction d'affichage du temps
displaytime() {
    local T=$1
    local D=$((T/60/60/24))
    local H=$((T/60/60%24))
    local M=$((T/60%60))
    local S=$((T%60))
    (( $D > 0 )) && printf '%d days ' $D
    (( $H > 0 )) && printf '%d hours ' $H
    (( $M > 0 )) && printf '%d minutes ' $M
    (( $T < 60 )) && printf '< 1 minutes'
}

# Fonction de calcul de taille en MB
get_size_mb() {
    local f=$1
    if [[ -f "$f" ]]; then
        local size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
        local tsize=$(echo "scale=2; $size / 1024 / 1024" | bc)
        if [[ ${tsize:0:1} == "." ]]; then tsize="0$tsize"; fi
        printf '%s' $tsize
    else
        printf '0'
    fi
}

# Fonction de calcul de taille en GB
get_size_gb() {
    local f=$1
    if [[ -f "$f" ]]; then
        local size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
        local tsize=$(echo "scale=2; $size / 1024 / 1024 / 1024" | bc)
        if [[ ${tsize:0:1} == "." ]]; then tsize="0$tsize"; fi
        printf '%s' $tsize
    else
        printf '0'
    fi
}

# Fonction de nettoyage en cas d'erreur
cleanup() {
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_error "Script interrompu avec le code d'erreur: $exit_code"
        BACKUP_STATUS="failed"
        ERROR_MESSAGE="Script interrompu avec le code d'erreur: $exit_code"

        # Nettoyage des fichiers temporaires
        for backup_file in "${BACKUP_FILES[@]}"; do
            [[ -f "$backup_file" ]] && rm -f "$backup_file"
            [[ -f "${backup_file}.gz" ]] && rm -f "${backup_file}.gz"
        done
    fi

    # Calcul de la durée finale
    BACKUP_DURATION=$(($(date +%s) - START_TIME))

    # Publication des métriques finales (sauf en mode check)
    [[ "$MODE" != "check" ]] && publish_metrics

    # Suppression du verrou
    [[ "$MODE" != "check" ]] && rm -f "$LOCK_FILE"

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
            "identifiers": ["mariadb_backup_monitor"],
            "name": "MariaDB Backup Monitor",
            "model": "MariaDB Backup Script",
            "manufacturer": "Custom Script",
            "sw_version": "2.0.0"
        },
        "origin": {
            "name": "MariaDB Backup Script"
        },
        "state_topic": "'$MQTT_STATE_TOPIC'",
        "components": {
            "mariadb_backup_status": {
                "platform": "sensor",
                "unique_id": "mariadb_backup_status",
                "object_id": "mariadb_backup_status",
                "has_entity_name": true,
                "force_update": true,
                "name": "Status",
                "icon": "mdi:database-check",
                "availability_mode": "all",
                "value_template": "{{ value_json.status }}",
                "device_class": null,
                "state_class": null
            },
            "mariadb_backup_duration": {
                "platform": "sensor",
                "unique_id": "mariadb_backup_duration",
                "object_id": "mariadb_backup_duration",
                "has_entity_name": true,
                "force_update": true,
                "name": "Duration",
                "icon": "mdi:timer-outline",
                "availability_mode": "all",
                "value_template": "{{ value_json.duration }}",
                "device_class": "duration",
                "unit_of_measurement": "s",
                "state_class": "measurement"
            },
            "mariadb_backup_size": {
                "platform": "sensor",
                "unique_id": "mariadb_backup_size",
                "object_id": "mariadb_backup_size",
                "has_entity_name": true,
                "force_update": true,
                "name": "Backup Size",
                "icon": "mdi:file-document-outline",
                "availability_mode": "all",
                "value_template": "{{ value_json.size_mb }}",
                "device_class": "data_size",
                "unit_of_measurement": "MB",
                "state_class": "measurement"
            },
            "mariadb_backup_compression": {
                "platform": "sensor",
                "unique_id": "mariadb_backup_compression",
                "object_id": "mariadb_backup_compression",
                "has_entity_name": true,
                "force_update": true,
                "name": "Compression Ratio",
                "icon": "mdi:archive",
                "availability_mode": "all",
                "value_template": "{{ value_json.compression_ratio }}",
                "device_class": null,
                "unit_of_measurement": "%",
                "state_class": "measurement"
            },
            "mariadb_backup_last_run": {
                "platform": "sensor",
                "unique_id": "mariadb_backup_last_run",
                "object_id": "mariadb_backup_last_run",
                "has_entity_name": true,
                "force_update": true,
                "name": "Last Backup",
                "icon": "mdi:clock-outline",
                "availability_mode": "all",
                "value_template": "{{ as_datetime(value_json.last_backup_timestamp) }}",
                "device_class": "timestamp"
            },
            "mariadb_backup_problem": {
                "platform": "binary_sensor",
                "unique_id": "mariadb_backup_problem",
                "object_id": "mariadb_backup_problem",
                "has_entity_name": true,
                "force_update": true,
                "name": "Backup Problem",
                "icon": "mdi:alert-circle",
                "availability_mode": "all",
                "value_template": "{{ \"failed\" if value_json.status in [\"failed\", \"dump_failed\", \"compression_failed\", \"pbs_failed\"] else \"success\" }}",
                "device_class": "problem",
                "payload_on": "failed",
                "payload_off": "success"
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
        \"size_mb\": $TOTAL_COMPRESSED_SIZE,
        \"compression_ratio\": $COMPRESSION_RATIO,
        \"backup_files\": \"$(IFS=,; echo "${BACKUP_FILES[*]##*/}")\",
        \"last_backup_timestamp\": \"$current_timestamp\",
        \"error_message\": \"$ERROR_MESSAGE\",
        \"backup_date\": \"$BACKUP_DATE\",
        \"days_kept\": $DAYS_TO_KEEP,
        \"max_local_backups\": $MAX_LOCAL_BACKUPS,
        \"pbs_enabled\": $([ "${PBS_ENABLED:-false}" = "true" ] && echo "true" || echo "false"),
        \"databases\": \"$(IFS=,; echo "${DB_NAMES[*]}")\",
        \"docker_container\": \"$DOCKER_CONTAINER_NAME\"
    }"

    # Publication du payload unifié sur le topic unique
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        ${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASSWORD:+-P "$MQTT_PASSWORD"} \
        -t "$MQTT_STATE_TOPIC" -m "$unified_payload" 2>/dev/null || true

    log_debug "Métriques publiées sur: $MQTT_STATE_TOPIC"
}

# ============================================================================
# FONCTIONS PBS (Proxmox Backup Server)
# ============================================================================

ensure_pbs_image() {
    local pbs_docker_image="${PBS_DOCKER_IMAGE:-proxmox-pbs-client:latest}"

    if docker image inspect "$pbs_docker_image" >/dev/null 2>&1; then
        log_debug "Image PBS déjà présente: $pbs_docker_image"
        return 0
    fi

    log_info "Image PBS non trouvée, construction via $REPO_ROOT/pbs_client/build_pbs_client.sh"

    if "$REPO_ROOT/pbs_client/build_pbs_client.sh" 2>&1 | tee -a "$LOG_FILE"; then
        log_info "Image '$pbs_docker_image' construite avec succès"
        return 0
    else
        log_error "Échec de la construction de l'image '$pbs_docker_image' via $REPO_ROOT/pbs_client/build_pbs_client.sh"
        return 1
    fi
}

check_pbs_connection() {
    log_info "=== Vérification de la connexion PBS ==="
    
    if [[ "${PBS_ENABLED:-false}" != "true" ]]; then
        log_error "PBS_ENABLED n'est pas activé dans la configuration"
        return 1
    fi

    if [[ -z "${PBS_REPOSITORY:-}" ]]; then
        log_error "PBS_REPOSITORY non défini"
        return 1
    fi

    if [[ -z "${PBS_PASSWORD:-}" ]]; then
        log_error "PBS_PASSWORD non défini"
        return 1
    fi

    # Vérifier et construire l'image si nécessaire
    if ! ensure_pbs_image; then
        log_error "Impossible de préparer l'image Docker PBS"
        return 1
    fi

    local image="${PBS_DOCKER_IMAGE:-ayufan/proxmox-backup-server:latest}"
    
    log_info "Repository: ${PBS_REPOSITORY_FULL}"
    log_info "Image Docker: ${image}"
    [[ -n "${PBS_FINGERPRINT:-}" ]] && log_info "Fingerprint: ${PBS_FINGERPRINT}"
    [[ -n "${PBS_NAMESPACE:-}" ]] && log_info "Namespace: ${PBS_NAMESPACE}"
    
    log_info "Test de connexion au serveur PBS..."
    
    # Test avec proxmox-backup-client login
    local test_result=0
    if docker run --rm --network host \
        -e "PBS_REPOSITORY=${PBS_REPOSITORY_FULL}" \
        -e "PBS_PASSWORD=${PBS_PASSWORD}" \
        ${PBS_FINGERPRINT:+-e "PBS_FINGERPRINT=${PBS_FINGERPRINT}"} \
        "$image" \
        login --repository "$PBS_REPOSITORY_FULL" 2>&1 | tee -a "$LOG_FILE"; then
        log_info "Connexion PBS réussie!"
        test_result=0
    else
        log_error "Échec de la connexion PBS"
        test_result=1
    fi
    
    return $test_result
}

pbs_is_enabled() {
    [[ "${PBS_ENABLED:-false}" == "true" ]]
}

pbs_run_backup() {
    local staging_dir="$1"
    local archive_name="${PBS_ARCHIVE_NAME:-elkarbackup.pxar}"
    local backup_id="${PBS_BACKUP_ID:-elkarbackup}"
    local backup_type="${PBS_BACKUP_TYPE:-host}"
    local pbs_namespace="${PBS_NAMESPACE:-}"
    local image="${PBS_DOCKER_IMAGE:-ayufan/proxmox-backup-server:latest}"

    # Vérifier et construire l'image si nécessaire
    if ! ensure_pbs_image; then
        log_error "Impossible de préparer l'image Docker PBS"
        return 1
    fi

    # En mode dummy-run, utiliser un backup_id différent
    if [[ "$MODE" == "dummy-run" ]]; then
        backup_id="${backup_id}-dummy"
        log_info "Mode DUMMY-RUN: Utilisation du backup_id: ${backup_id}"
    fi

    if [[ -z "${PBS_REPOSITORY:-}" ]]; then
        log_error "PBS_REPOSITORY non défini"
        return 1
    fi

    log_info "Envoi vers PBS: repository='${PBS_REPOSITORY_FULL}', backup_id='${backup_id}', type='${backup_type}'"

    local -a pbs_args=(
        backup
        "${archive_name}:/data"
        --backup-id "$backup_id"
        --backup-type "$backup_type"
        ${pbs_namespace:+--ns "$pbs_namespace"}
        --repository "$PBS_REPOSITORY_FULL"
    )

    docker run --rm --network host \
        -v "${staging_dir}:/data:ro" \
        -e "PBS_REPOSITORY=${PBS_REPOSITORY_FULL}" \
        ${PBS_PASSWORD:+-e "PBS_PASSWORD=${PBS_PASSWORD}"} \
        ${PBS_FINGERPRINT:+-e "PBS_FINGERPRINT=${PBS_FINGERPRINT}"} \
        "$image" \
        "${pbs_args[@]}" \
            2>>"$LOG_FILE"
}

pbs_backup_files() {
    local -a files=("$@")

    if ! pbs_is_enabled; then
        log_info "PBS désactivé, transfert ignoré"
        return 0
    fi

    local source_dir="${BACKUP_SOURCE_DIR}"
    local backup_dir="${BACKUP_DIR%/}"
    local source_name="${source_dir##*/}"
    local backup_name="${backup_dir##*/}"

    local source_safe
    local backup_safe
    source_safe=$(sanitize_name "$source_name")
    backup_safe=$(sanitize_name "$backup_name")

    local image="${PBS_DOCKER_IMAGE:-ayufan/proxmox-backup-server:latest}"

    # Construire les mounts et specs
    local -a mounts=()
    local -a specs=()
    if [[ "$PBS_CLIENT_MODE" == "docker" ]]; then
        mounts+=("--volume" "${source_dir}:/source:ro")
        specs+=("${source_safe}.pxar:/source")
        mounts+=("--volume" "${backup_dir}:/backups:ro")
        specs+=("${backup_safe}.pxar:/backups")
    else
        specs+=("${source_safe}.pxar:${source_dir}")
        specs+=("${backup_safe}.pxar:${backup_dir}")
    fi

    # Arguments additionnels: exclure les répertoires indésirables
    local -a extra_args_local=()
    extra_args_local+=(--exclude "backup" --exclude "mariadb/db")
    if [[ -n "${PBS_CHANGE_DETECTION_MODE:-}" ]]; then
        extra_args_local+=(--change-detection-mode "$PBS_CHANGE_DETECTION_MODE")
    fi
    if [[ -n "${PBS_CLIENT_EXTRA_ARGS:-}" ]]; then
        read -r -a extra_user_args <<< "$PBS_CLIENT_EXTRA_ARGS"
        extra_args_local+=("${extra_user_args[@]}")
    fi

    log_info "Envoi PBS direct: repository='${PBS_REPOSITORY_FULL}', source='${source_dir}', backups='${backup_dir}'"

    if [[ "$PBS_CLIENT_MODE" == "docker" ]]; then
        local -a pbs_args=(
            backup
            "${specs[@]}"
            --backup-id "${PBS_BACKUP_ID:-elkarbackup}"
            --backup-type "${PBS_BACKUP_TYPE:-host}"
            ${PBS_NAMESPACE:+--ns "$PBS_NAMESPACE"}
            --repository "${PBS_REPOSITORY_FULL}"
            "${extra_args_local[@]}"
        )

        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo "DRY-RUN: docker run --rm --network host ${mounts[*]} -e PBS_REPOSITORY=${PBS_REPOSITORY_FULL} $image ${pbs_args[*]}"
            return 0
        fi

        docker run --rm --network host \
            "${mounts[@]}" \
            -e "PBS_REPOSITORY=${PBS_REPOSITORY_FULL}" \
            ${PBS_PASSWORD:+-e "PBS_PASSWORD=${PBS_PASSWORD}"} \
            ${PBS_FINGERPRINT:+-e "PBS_FINGERPRINT=${PBS_FINGERPRINT}"} \
            "$image" \
            "${pbs_args[@]}" \
            2>>"$LOG_FILE"

        return $?
    else
        # apt mode
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo "DRY-RUN: proxmox-backup-client backup ${specs[*]} --repository ${PBS_REPOSITORY_FULL} --backup-id ${PBS_BACKUP_ID:-elkarbackup} --backup-type ${PBS_BACKUP_TYPE:-host} ${extra_args_local[*]}"
            return 0
        fi

        env ${PBS_FINGERPRINT:+PBS_FINGERPRINT="$PBS_FINGERPRINT"} \
            ${PBS_PASSWORD:+PBS_PASSWORD="$PBS_PASSWORD"} \
            proxmox-backup-client backup "${specs[@]}" --repository "$PBS_REPOSITORY_FULL" --backup-id "${PBS_BACKUP_ID:-elkarbackup}" --backup-type "${PBS_BACKUP_TYPE:-host}" ${PBS_NAMESPACE:+--ns "$PBS_NAMESPACE"} "${extra_args_local[@]}" 2>>"$LOG_FILE"

        return $?
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
    local database="$1"
    local backup_file="${BACKUP_DIR}${BACKUP_DATE}_${database}${FILE_SUFFIX}"
    
    log_info "Début de la sauvegarde de la base de données: $database"

    # Ajout du fichier à la liste pour le nettoyage
    BACKUP_FILES+=("$backup_file")

    if [[ "$TEST_MODE" == "true" ]]; then
        log_info "MODE TEST: Création d'un fichier dummy pour la base '$database'"
        create_dummy_backup "$backup_file" "$database"
        local result=$?
        if [[ $result -eq 0 ]]; then
            # Tracker la taille du fichier
            local file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file")
            local file_size_mb=$(echo "scale=2; $file_size / 1024 / 1024" | bc)
            TOTAL_BACKUP_SIZE=$((TOTAL_BACKUP_SIZE + file_size))
            TOTAL_COMPRESSED_SIZE=$(echo "scale=2; $TOTAL_COMPRESSED_SIZE + $file_size_mb" | bc)
            log_debug "Taille du fichier dummy: ${file_size_mb}MB"
        fi
        return $result
    else
        # Commande de dump MariaDB (exécutée directement, sans /bin/bash -c)
        log_debug "Dump MariaDB pour la base: $database (user: $DB_USER)"

        if docker exec -i mariadb mariadb-dump -u"${DB_USER}" -p"${DB_PASSWORD}" --databases "${database}" --skip-comments --single-transaction --routines --triggers > "$backup_file" 2>>"$LOG_FILE"; then
            log_info "Dump de la base de données '$database' réussi"

            if [[ "$VERIFY_BACKUP" == "true" ]]; then
                verify_backup_integrity "$backup_file"
            fi

            # Tracker la taille du fichier
            local file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file")
            local file_size_mb=$(echo "scale=2; $file_size / 1024 / 1024" | bc)
            TOTAL_BACKUP_SIZE=$((TOTAL_BACKUP_SIZE + file_size))
            TOTAL_COMPRESSED_SIZE=$(echo "scale=2; $TOTAL_COMPRESSED_SIZE + $file_size_mb" | bc)
            log_debug "Taille du fichier: ${file_size_mb}MB"

            return 0
        else
            log_error "Échec du dump de la base de données '$database'"
            return 1
        fi
    fi
}

create_dummy_backup() {
    local backup_file="$1"
    local database="$2"
    
    log_debug "Création d'un fichier dummy de test pour '$database'"

    # Création du fichier dummy avec dd
    if dd if=/dev/urandom of="$backup_file" bs=1M count="$DUMMY_FILE_SIZE_MB" 2>>"$LOG_FILE"; then
        log_info "Fichier dummy créé: $(basename "$backup_file") (${DUMMY_FILE_SIZE_MB}MB)"

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

        if [[ "$VERIFY_BACKUP" == "true" ]]; then
            verify_dummy_backup "$backup_file"
        fi

        return 0
    else
        log_error "Échec de la création du fichier dummy pour '$database'"
        return 1
    fi
}

verify_dummy_backup() {
    local backup_file="$1"
    log_debug "Vérification du fichier dummy: $(basename "$backup_file")"

    if [[ -f "$backup_file" && -s "$backup_file" ]]; then
        local file_size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file")
        local expected_min_size=$((DUMMY_FILE_SIZE_MB * 1024 * 1024 / 2))  # Au moins 50% de la taille attendue

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
    local backup_file="$1"
    log_debug "Vérification de l'intégrité de la sauvegarde: $(basename "$backup_file")"

    if [[ -f "$backup_file" && -s "$backup_file" ]]; then
        # Vérification basique du contenu SQL
        if grep -q "CREATE DATABASE" "$backup_file" && grep -q "USE " "$backup_file"; then
            log_debug "Fichier de sauvegarde valide"
            return 0
        else
            log_error "Fichier de sauvegarde invalide: contenu SQL incorrect"
            return 1
        fi
    else
        log_error "Fichier de sauvegarde invalide ou vide"
        return 1
    fi
}

cleanup_old_backups() {
    local database="$1"
    
    log_info "Nettoyage des anciennes sauvegardes pour '$database' (conservation: ${DAYS_TO_KEEP} jours, max local: ${MAX_LOCAL_BACKUPS})"

    # Nettoyage par âge
    local deleted_count=0
    while IFS= read -r -d '' file; do
        log_debug "Suppression de l'ancienne sauvegarde: $(basename "$file")"
        rm -f "$file"
        deleted_count=$((deleted_count + 1))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -mtime +$DAYS_TO_KEEP -name "*${database}${FILE_SUFFIX}" -print0 2>/dev/null)

    # Nettoyage par nombre (garder seulement les N plus récents)
    local backup_count=$(find "$BACKUP_DIR" -maxdepth 1 -name "*${database}${FILE_SUFFIX}" 2>/dev/null | wc -l)
    if [[ $backup_count -gt $MAX_LOCAL_BACKUPS ]]; then
        local to_delete=$((backup_count - MAX_LOCAL_BACKUPS))
        log_info "Suppression de $to_delete sauvegarde(s) pour respecter la limite de $MAX_LOCAL_BACKUPS"
        
        find "$BACKUP_DIR" -maxdepth 1 -name "*${database}${FILE_SUFFIX}" -type f -printf '%T@ %p\n' 2>/dev/null | \
        sort -n | head -n "$to_delete" | cut -d' ' -f2- | \
        while IFS= read -r file; do
            log_debug "Suppression pour limite de nombre: $(basename "$file")"
            rm -f "$file"
            deleted_count=$((deleted_count + 1))
        done
    fi

    log_info "Suppression de $deleted_count ancienne(s) sauvegarde(s) pour '$database'"
}

# ============================================================================
# FONCTION PRINCIPALE
# ============================================================================

main() {
    log_info "=== Début de la sauvegarde MariaDB ==="
    log_info "Bases de données à sauvegarder: $(IFS=,; echo "${DB_NAMES[*]}")"

    # Publication de la découverte MQTT au début
    publish_mqtt_discovery

    # Initialisation du statut
    BACKUP_STATUS="running"
    publish_metrics

    # Création des répertoires de sauvegarde
    create_backup_directory

    # Sauvegarde de chaque base de données
    local all_dumps_successful=true
    local backup_files_for_pbs=()

    for db_name in "${DB_NAMES[@]}"; do
        log_info "Traitement de la base de données: $db_name"
        
        if perform_database_dump "$db_name"; then
            local backup_file="${BACKUP_DIR}${BACKUP_DATE}_${db_name}${FILE_SUFFIX}"
            
            # Ajouter directement le fichier à PBS sans compression locale
            backup_files_for_pbs+=("$backup_file")
            log_info "Dump de la base de données réussi pour '$db_name' (sera compressé par PBS)"
            cleanup_old_backups "$db_name"
        else
            log_error "Échec du dump pour '$db_name'"
            all_dumps_successful=false
        fi
    done
    
    # Pas de compression locale, les fichiers seront compressés par PBS
    COMPRESSION_RATIO=0

    # Envoi vers PBS (inclut les dump SQL + répertoire parent via symlink)
    local pbs_successful=true
    if [[ ${#backup_files_for_pbs[@]} -gt 0 ]]; then
        if ! pbs_backup_files "${backup_files_for_pbs[@]}"; then
            log_warn "Sauvegardes créées localement mais échec de l'envoi PBS"
            pbs_successful=false
        else
            log_info "Envoi PBS réussi"
        fi
    fi

    # Détermination du statut final
    if [[ "$all_dumps_successful" == true ]]; then
        if [[ "$pbs_successful" == true ]]; then
            BACKUP_STATUS="success"
            log_info "=== Sauvegarde terminée avec succès ==="
        else
            BACKUP_STATUS="pbs_failed"
            ERROR_MESSAGE="Sauvegardes locales réussies mais échec de l'envoi PBS"
            log_warn "Sauvegarde locale réussie mais problèmes d'envoi PBS"
        fi
    else
        BACKUP_STATUS="dump_failed"
        ERROR_MESSAGE="Échec partiel ou total du dump des bases de données"
        log_error "Problèmes de dump détectés"
    fi

    # Calcul de la durée finale
    BACKUP_DURATION=$(($(date +%s) - START_TIME))

    log_info "Durée totale: ${BACKUP_DURATION}s ($(displaytime $BACKUP_DURATION))"
    log_info "Taille finale compressée: ${TOTAL_COMPRESSED_SIZE}MB"
    log_info "Ratio de compression: ${COMPRESSION_RATIO}%"
    log_info "Fichiers sauvegardés: $(IFS=,; echo "${BACKUP_FILES[*]##*/}")"
}

# ============================================================================
# VÉRIFICATIONS PRÉALABLES
# ============================================================================

check_dependencies() {
    local missing_deps=()

    # Vérification des outils requis
    for tool in docker bc; do
        if ! command -v "$tool" &> /dev/null; then
            missing_deps+=("$tool")
        fi
    done

    # Vérification des outils optionnels
    if [[ "$MQTT_ENABLED" == "true" ]] && ! command -v mosquitto_pub &> /dev/null; then
        missing_deps+=("mosquitto-clients")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Dépendances manquantes: ${missing_deps[*]}"
        exit 1
    fi
}

# ============================================================================
# POINT D'ENTRÉE
# ============================================================================

# Mode check: vérifier seulement la connexion PBS
if [[ "$MODE" == "check" ]]; then
    # Créer un fichier de log temporaire pour le mode check
    LOG_FILE="${LOG_FILE:-/tmp/backup_elkarbackup_check.log}"
    touch "$LOG_FILE"
    
    # Vérifier les dépendances minimales
    check_dependencies
    
    # Tenter la connexion PBS
    check_pbs_connection
    exit $?
fi

# Pour les autres modes, continuer avec les vérifications normales
check_dependencies

# Création du fichier de log si nécessaire
touch "$LOG_FILE"

# Exécution principale
main

log_info "=== Script terminé ==="

