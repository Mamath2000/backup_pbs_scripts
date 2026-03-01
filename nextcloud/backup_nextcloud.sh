#!/bin/bash
#
# Script de sauvegarde Nextcloud AIO amélioré
# Fonctionnalités:
# - Envoi vers Proxmox Backup Server (PBS)
# - Publication de métriques vers Home Assistant via MQTT
# - Gestion d'erreurs robuste
# - Logging détaillé
# - Configuration centralisée
# - Sauvegarde locale limitée + distant PBS
# - Dump du répertoire de configuration
#
# Usage:
#   ./backup_nextcloud.sh [--backup|--check|--dummy-run|--help]
#   --backup    : Mode normal de sauvegarde
#   --check     : Vérifie uniquement la connexion PBS
#   --dummy-run : Mode test avec fichiers dummy
#   --help      : Affiche l'aide (par défaut si aucun argument)
#

set -euo pipefail

# Répertoire du script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup_nextcloud.conf"

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

# Parse des arguments
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
LOCK_FILE="${SCRIPT_DIR}/.backup_nextcloud.lock"

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
# Si PBS_REPOSITORY contient déjà un datastore (ex: user@realm@host:ds), on l'utilise tel quel
# sauf si --datastore est passé en argument
PBS_DATASTORE="${PBS_DATASTORE_DEFAULT:-}"
if [[ -n "$PBS_DATASTORE_ARG" ]]; then
    # --datastore CLI a priorité absolue : on strip l'éventuel datastore du repo et on ajoute le bon
    PBS_REPOSITORY_FULL="${PBS_REPOSITORY%%:*}:${PBS_DATASTORE_ARG}"
elif [[ "$PBS_REPOSITORY" == *:* ]]; then
    # PBS_REPOSITORY contient déjà le datastore
    PBS_REPOSITORY_FULL="$PBS_REPOSITORY"
elif [[ -n "$PBS_DATASTORE" ]]; then
    PBS_REPOSITORY_FULL="$PBS_REPOSITORY:$PBS_DATASTORE"
else
    echo "ERREUR: PBS_REPOSITORY ne contient pas de datastore et PBS_DATASTORE_DEFAULT n'est pas défini" >&2
    exit 1
fi

# Mode client PBS par défaut
PBS_CLIENT_MODE="${PBS_CLIENT_MODE:-docker}"

# Défauts pour les variables de sauvegarde
COMPRESSION_LEVEL=0  # Pas de compression locale: PBS gère la déduplication nativement
DAYS_TO_KEEP="${DAYS_TO_KEEP:-10}"
MAX_LOCAL_BACKUPS="${MAX_LOCAL_BACKUPS:-2}"
FILE_SUFFIX="${FILE_SUFFIX:-_nextcloud_backup.sql}"

# Fichier de log par défaut dans un sous-répertoire 'logs' du script
LOG_FILE="${SCRIPT_DIR}/logs/backup_nextcloud.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "${LOG_FILE}") 2>&1

# MQTT topics and defaults: ensure variables are defined and topics built from PBS_BACKUP_ID
# Les topics sont construits en dur comme dans la CLI
MQTT_DEVICE_TOPIC="homeassistant/device/backup/${PBS_BACKUP_ID}/config"
MQTT_STATE_TOPIC="backup/${PBS_BACKUP_ID}/state"

# Defaults MQTT (sécurise les variables non définies dans le fichier de conf)
MQTT_ENABLED="${MQTT_ENABLED:-false}"
MQTT_HOST="${MQTT_HOST:-}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASSWORD="${MQTT_PASSWORD:-}"

# Valeurs par défaut pour les variables optionnelles
DUMMY_FILE_SIZE_MB="${DUMMY_FILE_SIZE_MB:-50}"

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

    echo "[$timestamp] [$level] $message"
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
            "identifiers": ["nextcloud_backup_monitor"],
            "name": "Nextcloud Backup Monitor",
            "model": "Nextcloud Backup Script",
            "manufacturer": "Custom Script",
            "sw_version": "2.0.0"
        },
        "origin": {
            "name": "Nextcloud Backup Script"
        },
        "state_topic": "'$MQTT_STATE_TOPIC'",
        "components": {
            "nextcloud_backup_status": {
                "platform": "sensor",
                "unique_id": "nextcloud_backup_status",
                "default_entity_id": "sensor.nextcloud_backup_status",
                "has_entity_name": true,
                "force_update": true,
                "name": "Status",
                "icon": "mdi:cloud-check",
                "availability_mode": "all",
                "value_template": "{{ value_json.status }}",
                "device_class": null,
                "state_class": null
            },
            "nextcloud_backup_duration": {
                "platform": "sensor",
                "unique_id": "nextcloud_backup_duration",
                "default_entity_id": "sensor.nextcloud_backup_duration",
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
            "nextcloud_backup_size": {
                "platform": "sensor",
                "unique_id": "nextcloud_backup_size",
                "default_entity_id": "sensor.nextcloud_backup_size",
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
            "nextcloud_backup_compression": {
                "platform": "sensor",
                "unique_id": "nextcloud_backup_compression",
                "default_entity_id": "sensor.nextcloud_backup_compression",
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
            "nextcloud_backup_last_run": {
                "platform": "sensor",
                "unique_id": "nextcloud_backup_last_run",
                "default_entity_id": "sensor.nextcloud_backup_last_run",
                "has_entity_name": true,
                "force_update": true,
                "name": "Last Backup",
                "icon": "mdi:clock-outline",
                "availability_mode": "all",
                "value_template": "{{ as_datetime(value_json.last_backup_timestamp) }}",
                "device_class": "timestamp"
            },            
            "nextcloud_backup_problem": {
                "platform": "binary_sensor",
                "unique_id": "nextcloud_backup_problem",
                "default_entity_id": "binary_sensor.nextcloud_backup_problem",
                "has_entity_name": true,
                "force_update": true,
                "name": "Backup Problem",
                "icon": "mdi:alert-circle",
                "availability_mode": "all",
                "value_template": "{{ \"failed\" if value_json.status in [\"failed\", \"dump_failed\", \"compression_failed\", \"pbs_failed\", \"config_failed\"] else \"success\" }}",
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
        \"compression_level\": $COMPRESSION_LEVEL,
        \"error_message\": \"$ERROR_MESSAGE\",
        \"backup_date\": \"$BACKUP_DATE\",
        \"days_kept\": $DAYS_TO_KEEP,
        \"max_local_backups\": $MAX_LOCAL_BACKUPS,
        \"pbs_repository\": \"${PBS_REPOSITORY:-}\",
        \"pbs_backup_id\": \"${PBS_BACKUP_ID:-}\",
        \"databases\": \"$DB_NAME\",
        \"docker_container\": \"$DOCKER_CONTAINER_NAME\"
    }"

    # Publication du payload unifié sur le topic unique
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        ${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASSWORD:+-P "$MQTT_PASSWORD"} \
        -t "$MQTT_STATE_TOPIC" -m "$unified_payload" 2>/dev/null || true

    log_debug "Métriques publiées sur: $MQTT_STATE_TOPIC"
}

# ============================================================================
# FONCTIONS PBS
# ============================================================================

ensure_pbs_image() {
    local image="${PBS_DOCKER_IMAGE:-proxmox-pbs-client:latest}"

    log_debug "Vérification de la présence de l'image Docker: $image"

    # Vérifier si l'image existe déjà
    if docker image inspect "$image" &>/dev/null; then
        log_debug "Image Docker '$image' trouvée"
        return 0
    fi

    log_warn "Image Docker '$image' non trouvée, construction en cours..."

    # Rechercher le docker-compose.yml pour construire l'image
    local compose_file="${REPO_ROOT}/pbs_client/docker-compose.yml"

    if [[ ! -f "$compose_file" ]]; then
        log_error "Impossible de trouver $compose_file pour construire l'image"
        log_error "Veuillez construire l'image manuellement avec: cd ${REPO_ROOT}/pbs_client && docker compose build"
        return 1
    fi

    log_info "Construction de l'image depuis: $compose_file"

    # Utiliser le script de build centralisé
    if "$REPO_ROOT/pbs_client/build_pbs_client.sh"; then
        log_info "✓ Image '$image' construite avec succès"
        return 0
    else
        log_error "✗ Échec de la construction de l'image '$image' via $REPO_ROOT/pbs_client/build_pbs_client.sh"
        return 1
    fi
}

check_pbs_connection() {
    log_info "=== Vérification de la connexion PBS ==="

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

    local image="${PBS_DOCKER_IMAGE:-proxmox-pbs-client:latest}"

    log_info "Repository: ${PBS_REPOSITORY_FULL:-$PBS_REPOSITORY}"
    [[ -n "${PBS_FINGERPRINT:-}" ]] && log_info "Fingerprint: ${PBS_FINGERPRINT}"
    [[ -n "${PBS_NAMESPACE:-}" ]] && log_info "Namespace: ${PBS_NAMESPACE}"

    log_info "Test de connexion au serveur PBS..."

    local test_result=0
    if docker run --rm --network host \
        -e "PBS_REPOSITORY=${PBS_REPOSITORY_FULL}" \
        ${PBS_PASSWORD:+-e "PBS_PASSWORD=${PBS_PASSWORD}"} \
        ${PBS_PASSWORD_FILE:+-e "PBS_PASSWORD_FILE=${PBS_PASSWORD_FILE}"} \
        ${PBS_FINGERPRINT:+-e "PBS_FINGERPRINT=${PBS_FINGERPRINT}"} \
        "$image" \
        list --repository "${PBS_REPOSITORY_FULL}" ${PBS_NAMESPACE:+--ns "$PBS_NAMESPACE"}; then
        log_info "Connexion PBS réussie!"
        test_result=0
    else
        log_error "Échec de la connexion PBS"
        test_result=1
    fi

    return $test_result
}

pbs_run_backup() {
    local staging_dir="$1"
    local archive_name="${PBS_ARCHIVE_NAME:-nextcloud-aio.pxar}"
    local backup_id="${PBS_BACKUP_ID:-nextcloud-aio}"
    local backup_type="${PBS_BACKUP_TYPE:-host}"
    local pbs_namespace="${PBS_NAMESPACE:-}"
    local ncaio_source_path="${NEXTCLOUD_AIO_SOURCE_PATH:-"$(dirname "$SCRIPT_DIR")"}"
    local ncaio_archive_name="${NEXTCLOUD_AIO_ARCHIVE_NAME:-nextcloud-aio-src.pxar}"
    local data_path="${NEXTCLOUD_DATA_PATH:-}"
    local data_archive_name="${NEXTCLOUD_DATA_ARCHIVE_NAME:-nextcloud-data.pxar}"
    local image="${PBS_DOCKER_IMAGE:-proxmox-pbs-client:latest}"

    # Vérifier et construire l'image si nécessaire
    if ! ensure_pbs_image; then
        log_error "Impossible de préparer l'image Docker PBS"
        return 1
    fi

    # En mode dummy-run, utiliser un backup_id différent et désactiver les données utilisateur
    if [[ "$MODE" == "dummy-run" ]]; then
        backup_id="${backup_id}-dummy"
        log_info "Mode DUMMY-RUN: Utilisation du backup_id: ${backup_id}"
        log_warn "Mode DUMMY-RUN: Sauvegarde des données utilisateur désactivée (NEXTCLOUD_DATA_PATH ignoré)"
        data_path=""
    fi

    if [[ -n "$data_path" ]]; then
        log_info "Inclusion des données Nextcloud: $data_path -> $data_archive_name"
    fi

    if [[ -z "${PBS_REPOSITORY:-}" ]]; then
        log_error "PBS_REPOSITORY non défini"
        return 1
    fi

    log_info "Envoi vers PBS: repository='${PBS_REPOSITORY_FULL}', backup_id='${backup_id}', type='${backup_type}'"

    local -a extra_mounts=()
    local -a backup_specs=("${archive_name}:/data")

    # Répertoire nextcloud-aio (meilleure dédup PBS qu'un tar.gz)
    if [[ -d "$ncaio_source_path" ]]; then
        extra_mounts+=("-v" "${ncaio_source_path}:/ncaio:ro")
        backup_specs+=("${ncaio_archive_name}:/ncaio")
    else
        log_error "NEXTCLOUD_AIO_SOURCE_PATH n'existe pas ou n'est pas un répertoire: $ncaio_source_path"
        return 1
    fi

    if [[ -n "$data_path" ]]; then
        if [[ -d "$data_path" ]]; then
            extra_mounts+=("-v" "${data_path}:/ncdata:ro")
            backup_specs+=("${data_archive_name}:/ncdata")
        else
            log_error "NEXTCLOUD_DATA_PATH n'existe pas ou n'est pas un répertoire: $data_path"
            return 1
        fi
    fi

    local -a pbs_args=(
        backup
        "${backup_specs[@]}"
        --backup-id "$backup_id"
        --backup-type "$backup_type"
        ${pbs_namespace:+--ns "$pbs_namespace"}
        --repository "$PBS_REPOSITORY_FULL"
        --exclude "/ncaio/backup"
        --exclude "/ncaio/mastercontainer"
    )

    docker run --rm --network host \
        -v "${staging_dir}:/data:ro" \
        "${extra_mounts[@]}" \
        -e "PBS_REPOSITORY=${PBS_REPOSITORY_FULL}" \
        ${PBS_PASSWORD:+-e "PBS_PASSWORD=${PBS_PASSWORD}"} \
        ${PBS_PASSWORD_FILE:+-e "PBS_PASSWORD_FILE=${PBS_PASSWORD_FILE}"} \
        ${PBS_FINGERPRINT:+-e "PBS_FINGERPRINT=${PBS_FINGERPRINT}"} \
        "$image" \
        "${pbs_args[@]}"
}

pbs_backup_files() {
    local -a files=("$@")


    local staging_dir
    staging_dir=$(mktemp -d -p "${BACKUP_DIR%/}" ".pbs-staging.${BACKUP_DATE}.XXXXXX")

    # Copie des artefacts dans un répertoire dédié pour un snapshot PBS propre
    for f in "${files[@]}"; do
        if [[ ! -f "$f" ]]; then
            log_error "Fichier introuvable pour PBS: $f"
            rm -rf "$staging_dir" || true
            return 1
        fi
        cp -f -- "$f" "$staging_dir/"
    done

        # Métadonnées (utile à la restauration)
        local json_files=""
        for f in "${files[@]}"; do
                json_files+="\"$(basename "$f")\"," 
        done
        json_files="${json_files%, }"

        cat >"$staging_dir/metadata.json" <<EOF
{
    "backup_date": "${BACKUP_DATE}",
    "db_name": "${DB_NAME}",
    "docker_container": "${DOCKER_CONTAINER_NAME}",
    "files": [${json_files}]
}
EOF

    if pbs_run_backup "$staging_dir"; then
        log_info "Envoi PBS réussi"
        rm -rf "$staging_dir" || true
        return 0
    fi

    log_error "Échec de l'envoi PBS"
    rm -rf "$staging_dir" || true
    return 1
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
    local backup_file="${BACKUP_DIR}${BACKUP_DATE}${FILE_SUFFIX}"
    
    log_info "Début de la sauvegarde de la base de données: $DB_NAME"

    # Ajout du fichier à la liste pour le nettoyage
    BACKUP_FILES+=("$backup_file")

    if [[ "$MODE" == "dummy-run" ]]; then
        log_info "MODE DUMMY-RUN: Création d'un fichier dummy"
        if create_dummy_backup "$backup_file"; then
            local size_bytes
            size_bytes=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file")
            local size_mb
            size_mb=$(get_size_mb "$backup_file")
            TOTAL_BACKUP_SIZE=$((TOTAL_BACKUP_SIZE + size_bytes))
            TOTAL_COMPRESSED_SIZE=$(echo "scale=2; $TOTAL_COMPRESSED_SIZE + $size_mb" | bc)
            return 0
        fi
        return 1
    else
        # Chemin temporaire dans le conteneur
        local temp_file="/mnt/data/${BACKUP_DATE}${FILE_SUFFIX}"
        
        # Commande de dump PostgreSQL
        local cmd="pg_dump -U ${DB_USER} ${DB_NAME} -F p -f ${temp_file}"

        log_debug "Commande de dump: $cmd"

        if docker exec -t "$DOCKER_ID" $cmd; then
            # Copie du fichier depuis le conteneur
            if docker cp "${DOCKER_ID}:${temp_file}" "$backup_file"; then
                # Suppression du fichier temporaire dans le conteneur
                docker exec "$DOCKER_ID" rm "$temp_file" 2>/dev/null || true
                
                log_info "Dump de la base de données '$DB_NAME' réussi"

                        # Vérification systématique du dump SQL (pas de paramètre nécessaire)
                            verify_backup_integrity "$backup_file" || true

                local size_bytes
                size_bytes=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file")
                local size_mb
                size_mb=$(get_size_mb "$backup_file")
                TOTAL_BACKUP_SIZE=$((TOTAL_BACKUP_SIZE + size_bytes))
                TOTAL_COMPRESSED_SIZE=$(echo "scale=2; $TOTAL_COMPRESSED_SIZE + $size_mb" | bc)

                return 0
            else
                log_error "Échec de la copie du dump depuis le conteneur"
                return 1
            fi
        else
            log_error "Échec du dump de la base de données '$DB_NAME'"
            return 1
        fi
    fi
}

create_dummy_backup() {
    local backup_file="$1"
    
    log_debug "Création d'un fichier dummy de test"

    # Création du fichier dummy avec dd
    if dd if=/dev/urandom of="$backup_file" bs=1M count="$DUMMY_FILE_SIZE_MB"; then
        log_info "Fichier dummy créé: $(basename "$backup_file") (${DUMMY_FILE_SIZE_MB}MB)"

        # Ajout d'un en-tête pour identifier le fichier comme étant un test
        {
            echo "-- PostgreSQL Backup Test File"
            echo "-- Created: $(date)"
            echo "-- Size: ${DUMMY_FILE_SIZE_MB}MB" 
            echo "-- Database: $DB_NAME (DUMMY RUN MODE)"
            echo "-- Container: $DOCKER_CONTAINER_NAME"
            echo "-- This is a dummy file for testing purposes"
            echo ""
            echo "CREATE DATABASE ${DB_NAME};"
            echo "\\c ${DB_NAME};"
            echo ""
            echo "-- Original dummy data follows..."
        } > /tmp/test_header

        # Concaténation de l'en-tête avec le fichier dummy
        cat /tmp/test_header "$backup_file" > "${backup_file}.tmp" && mv "${backup_file}.tmp" "$backup_file"
        rm -f /tmp/test_header

        # Vérification systématique du dummy (pas de paramètre nécessaire)
        verify_dummy_backup "$backup_file" || true

        return 0
    else
        log_error "Échec de la création du fichier dummy"
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
        # Vérification basique du contenu PostgreSQL
        if grep -q "PostgreSQL database dump" "$backup_file" || grep -q "CREATE " "$backup_file"; then
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
    log_info "Nettoyage des anciennes sauvegardes (conservation: ${DAYS_TO_KEEP} jours, max local: ${MAX_LOCAL_BACKUPS})"

    # Nettoyage par âge
    local deleted_count=0
    while IFS= read -r -d '' file; do
        log_debug "Suppression de l'ancienne sauvegarde: $(basename "$file")"
        rm -f "$file"
        deleted_count=$((deleted_count + 1))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -mtime +$DAYS_TO_KEEP \( -name "*${FILE_SUFFIX}" -o -name "*${FILE_SUFFIX}.gz" \) -print0 2>/dev/null)

    # Nettoyage par nombre (garder seulement les N plus récents)
    local backup_count
    backup_count=$(find "$BACKUP_DIR" -maxdepth 1 \( -name "*${FILE_SUFFIX}" -o -name "*${FILE_SUFFIX}.gz" \) 2>/dev/null | wc -l)
    if [[ $backup_count -gt $MAX_LOCAL_BACKUPS ]]; then
        local to_delete=$((backup_count - MAX_LOCAL_BACKUPS))
        log_info "Suppression de $to_delete sauvegarde(s) pour respecter la limite de $MAX_LOCAL_BACKUPS"
        
        find "$BACKUP_DIR" -maxdepth 1 \( -name "*${FILE_SUFFIX}" -o -name "*${FILE_SUFFIX}.gz" \) -type f -printf '%T@ %p\n' 2>/dev/null | \
        sort -n | head -n "$to_delete" | cut -d' ' -f2- | \
        while IFS= read -r file; do
            log_debug "Suppression pour limite de nombre: $(basename "$file")"
            rm -f "$file"
            deleted_count=$((deleted_count + 1))
        done
    fi

    log_info "Suppression de $deleted_count ancienne(s) sauvegarde(s)"
}

# ============================================================================
# FONCTIONS DE DUMP DU RÉPERTOIRE
# ============================================================================

create_directory_dump() {
    log_info "=== Début du dump du répertoire parent ==="
    
    # Répertoire parent (nextcloud-aio)
    local source_dir="$(dirname "$SCRIPT_DIR")"
    local dump_file="${BACKUP_DIR}${BACKUP_DATE}_nextcloud_directory_dump.tar.gz"
    
    log_info "Création du dump du répertoire: $source_dir"
    log_info "Fichier de dump: $(basename "$dump_file")"
    
    # Ajout du fichier à la liste pour le nettoyage
    BACKUP_FILES+=("$dump_file")
    
    # Création du dump en excluant les répertoires backup et mastercontainer
    if tar --exclude='./backup' --exclude='./mastercontainer' \
           -czf "$dump_file" \
           -C "$source_dir" .; then
        
        local dump_size=$(get_size_mb "$dump_file")
        log_info "Dump du répertoire créé avec succès (taille: ${dump_size}MB)"
        
        # Mise à jour de la taille totale
        TOTAL_COMPRESSED_SIZE=$(echo "scale=2; $TOTAL_COMPRESSED_SIZE + $dump_size" | bc)
        
        return 0
    else
        log_error "Échec de la création du dump du répertoire"
        return 1
    fi
}

cleanup_old_directory_dumps() {
    log_info "Nettoyage des anciens dumps de répertoire (conservation: ${DAYS_TO_KEEP} jours, max local: ${MAX_LOCAL_BACKUPS})"

    # Nettoyage par âge
    local deleted_count=0
    while IFS= read -r -d '' file; do
        log_debug "Suppression de l'ancien dump: $(basename "$file")"
        rm -f "$file"
        deleted_count=$((deleted_count + 1))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -mtime +$DAYS_TO_KEEP -name "*_directory_dump.tar.gz" -print0 2>/dev/null)

    # Nettoyage par nombre (garder seulement les N plus récents)
    local dump_count=$(find "$BACKUP_DIR" -maxdepth 1 -name "*_directory_dump.tar.gz" 2>/dev/null | wc -l)
    if [[ $dump_count -gt $MAX_LOCAL_BACKUPS ]]; then
        local to_delete=$((dump_count - MAX_LOCAL_BACKUPS))
        log_info "Suppression de $to_delete dump(s) pour respecter la limite de $MAX_LOCAL_BACKUPS"
        
        find "$BACKUP_DIR" -maxdepth 1 -name "*_directory_dump.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | \
        sort -n | head -n "$to_delete" | cut -d' ' -f2- | \
        while IFS= read -r file; do
            log_debug "Suppression pour limite de nombre: $(basename "$file")"
            rm -f "$file"
            deleted_count=$((deleted_count + 1))
        done
    fi

    log_info "Suppression de $deleted_count ancien(s) dump(s) de répertoire"
}

export_nextcloud_config() {
    local volume_name="${NEXTCLOUD_VOLUME_NAME:-nextcloud_aio_nextcloud}"
    local container_path="${NEXTCLOUD_CONFIG_PATH:-/var/www/html/config/config.php}"
    local output_file="${BACKUP_DIR}${BACKUP_DATE}_nextcloud_config.php"

    log_info "Export du fichier config.php depuis le volume Nextcloud"

    BACKUP_FILES+=("$output_file")

    # Lecture via un conteneur temporaire (inspiré de l'édition via alpine), mais en lecture seule
    if docker run --rm \
        --volume "${volume_name}:/var/www/html:ro" \
        alpine sh -lc "cat '${container_path}'" >"$output_file"; then

        if [[ ! -s "$output_file" ]]; then
            log_error "config.php exporté mais vide: $output_file"
            return 1
        fi

        local cfg_size
        cfg_size=$(get_size_mb "$output_file")
        log_info "config.php exporté: $(basename "$output_file") (${cfg_size}MB)"

        TOTAL_COMPRESSED_SIZE=$(echo "scale=2; $TOTAL_COMPRESSED_SIZE + $cfg_size" | bc)
        return 0
    fi

    log_error "Échec de l'export de config.php (volume='${volume_name}', path='${container_path}')"
    return 1
}

cleanup_old_config_exports() {
    log_info "Nettoyage des anciens exports config.php (conservation: ${DAYS_TO_KEEP} jours, max local: ${MAX_LOCAL_BACKUPS})"

    local deleted_count=0
    while IFS= read -r -d '' file; do
        log_debug "Suppression de l'ancien export config.php: $(basename "$file")"
        rm -f "$file"
        deleted_count=$((deleted_count + 1))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -mtime +$DAYS_TO_KEEP -name "*_nextcloud_config.php" -print0 2>/dev/null)

    local cfg_count
    cfg_count=$(find "$BACKUP_DIR" -maxdepth 1 -name "*_nextcloud_config.php" 2>/dev/null | wc -l)
    if [[ $cfg_count -gt $MAX_LOCAL_BACKUPS ]]; then
        local to_delete=$((cfg_count - MAX_LOCAL_BACKUPS))
        log_info "Suppression de $to_delete export(s) config.php pour respecter la limite de $MAX_LOCAL_BACKUPS"

        find "$BACKUP_DIR" -maxdepth 1 -name "*_nextcloud_config.php" -type f -printf '%T@ %p\n' 2>/dev/null | \
        sort -n | head -n "$to_delete" | cut -d' ' -f2- | \
        while IFS= read -r file; do
            log_debug "Suppression pour limite de nombre: $(basename "$file")"
            rm -f "$file"
            deleted_count=$((deleted_count + 1))
        done
    fi

    log_info "Suppression de $deleted_count ancien(s) export(s) config.php"
}

# ============================================================================
# FONCTION PRINCIPALE
# ============================================================================

main() {
    log_info "=== Début de la sauvegarde Nextcloud AIO ==="
    log_info "Base de données: $DB_NAME"

    # Publication de la découverte MQTT au début
    publish_mqtt_discovery

    # Initialisation du statut
    BACKUP_STATUS="running"
    publish_metrics

    # Création du répertoire de sauvegarde
    create_backup_directory

    # Sauvegarde de la base de données (non compressée: PBS gère mieux compression + dédup)
    local dump_successful=true
    local pbs_successful=true

    local backup_file="${BACKUP_DIR}${BACKUP_DATE}${FILE_SUFFIX}"
    local config_file=""

    if perform_database_dump; then
        log_info "Sauvegarde de base de données complète réussie"
        cleanup_old_backups
    else
        log_error "Échec du dump"
        dump_successful=false
    fi

    # Ratio de compression local: non pertinent ici (on laisse PBS s'en charger)
    COMPRESSION_RATIO=0

    # Export du config.php (volume Nextcloud)
    local config_export_successful=true
    if export_nextcloud_config; then
        config_file="${BACKUP_DIR}${BACKUP_DATE}_nextcloud_config.php"
        cleanup_old_config_exports
    else
        config_export_successful=false
    fi

    # Envoi distant PBS (DB + config.php). Le répertoire nextcloud-aio est sauvegardé directement par pbs_run_backup().
    if [[ "$dump_successful" == true && "$config_export_successful" == true ]]; then
        if ! pbs_backup_files "$backup_file" "$config_file"; then
            pbs_successful=false
        fi
    else
        pbs_successful=false
    fi

    # Détermination du statut final
    if [[ "$dump_successful" != true ]]; then
        BACKUP_STATUS="dump_failed"
        ERROR_MESSAGE="Échec du dump de la base de données"
        log_error "Problèmes de dump détectés"
    elif [[ "$config_export_successful" != true ]]; then
        BACKUP_STATUS="config_failed"
        ERROR_MESSAGE="Échec de l'export du config.php"
        log_error "Problèmes d'export config.php détectés"
    elif [[ "$pbs_successful" != true ]]; then
        BACKUP_STATUS="pbs_failed"
        ERROR_MESSAGE="Échec partiel ou total de l'envoi PBS"
        log_warn "Sauvegarde locale réussie mais problème d'envoi PBS"
    else
        BACKUP_STATUS="success"
        log_info "=== Sauvegarde terminée avec succès ==="
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

    # docker est requis pour le fonctionnement PBS/docker
    if ! command -v docker &> /dev/null; then
        missing_deps+=("docker")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Dépendances manquantes: ${missing_deps[*]}"
        exit 1
    fi
}

# ============================================================================
# POINT D'ENTRÉE
# ============================================================================

# Vérifications initiales
check_dependencies

# Création du fichier de log si nécessaire
touch "$LOG_FILE"

# Exécution selon le mode
case "$MODE" in
    check)
        log_info "=== Mode CHECK: Vérification de la connexion PBS ==="
        if check_pbs_connection; then
            log_info "✓ Vérification réussie"
            rm -f "$LOCK_FILE" 2>/dev/null || true
            exit 0
        else
            log_error "✗ Vérification échouée"
            rm -f "$LOCK_FILE" 2>/dev/null || true
            exit 1
        fi
        ;;
    dummy-run)
        log_info "=== Mode DUMMY-RUN: Sauvegarde test avec fichiers dummy ==="
        main
        ;;
    backup|*)
        log_info "=== Mode BACKUP: Sauvegarde normale ==="
        main
        ;;
esac

log_info "=== Script terminé ==="