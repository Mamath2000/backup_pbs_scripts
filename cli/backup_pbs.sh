#!/usr/bin/env bash
#
# Script simple de backup vers Proxmox Backup Server (PBS)
# - Support proxmox-backup-client via apt ou docker
# - Configuration dans un fichier .conf (pas de .env)
# - Appel: ./backup_pbs.sh "nom-backup" /path/1 /path/2 ...
# - Pas de compression (pxar natif PBS)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"


# Vérification des droits sur le fichier de configuration

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERREUR: Fichier de configuration introuvable: $CONFIG_FILE" >&2
    exit 1
fi


# Initialisation LOG_FILE pour usage précoce
LOG_FILE="/tmp/backup_pbs.log"
# Définition de log() avant tout usage
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $msg" | tee -a "${LOG_FILE}"
}

# Vérification des droits sur le fichier de configuration
conf_perm=$(stat -c "%a" "$CONFIG_FILE")
if [[ "$conf_perm" != "600" ]]; then
    echo "ERREUR: Les droits sur $CONFIG_FILE doivent être 600 (actuellement $conf_perm)" >&2
    log "ERROR" "Droits insuffisants sur $CONFIG_FILE (actuellement $conf_perm, attendu 600)"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $msg" | tee -a "${LOG_FILE}"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") "nom-backup" -d /chemin/unique [-e /chemin/exclu]...

Options:
    --check [--datastore NAME] [--namespace NAME] : Tester la connexion au serveur PBS (sans effectuer de backup). Vous pouvez préciser un datastore via `--datastore` et/ou un namespace via `--namespace`.

Exemples:
    $(basename "$0") host-prod -d /etc
    $(basename "$0") host-prod -d /etc -e /etc/ssl -e /etc/hostname
    $(basename "$0") --check --datastore ds3 --namespace Hosts
EOF
}

require_var() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        log "ERROR" "Variable requise manquante: $name"
        exit 1
    fi
}

sanitize_name() {
    # Remplace tout caractère non alphanum/underscore par underscore
    echo "$1" | tr -c '[:alnum:]_-' '_' | sed 's/_\+/_/g' | sed 's/^_//;s/_$//'
}


# Mode test de connexion : ./backup_pbs.sh --check [--datastore <name>]
if [[ "${1:-}" == "--check" ]]; then
    log "INFO" "Mode test de connexion à PBS activé."
    # s'assurer des valeurs par défaut nécessaires
    PBS_CLIENT_MODE="${PBS_CLIENT_MODE:-apt}"
    PBS_DOCKER_IMAGE="${PBS_DOCKER_IMAGE:-proxmox-pbs-client:latest}"

    require_var PBS_REPOSITORY

    # parse optional args for check (--datastore and --namespace supported)
    PBS_DATASTORE="${PBS_DATASTORE_DEFAULT:-backup}"
    PBS_DATASTORE_ARG=""
    PBS_NAMESPACE_ARG=""
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --datastore)
                shift
                PBS_DATASTORE_ARG="${1:-}"
                ;;
            --namespace|--ns)
                shift
                PBS_NAMESPACE_ARG="${1:-}"
                ;;
            *)
                log "ERROR" "Argument inconnu pour --check : $1"
                exit 1
                ;;
        esac
        shift
    done

    if [[ -n "$PBS_DATASTORE_ARG" ]]; then
        PBS_REPOSITORY_FULL="$PBS_REPOSITORY:$PBS_DATASTORE_ARG"
    else
        PBS_REPOSITORY_FULL="$PBS_REPOSITORY:$PBS_DATASTORE"
    fi

    # effective namespace: prefer CLI arg, then config
    EFFECTIVE_PBS_NAMESPACE="${PBS_NAMESPACE_ARG:-${PBS_NAMESPACE:-}}"

    if [[ -z "${PBS_PASSWORD:-}" && -z "${PBS_PASSWORD_FILE:-}" ]]; then
        log "ERROR" "PBS_PASSWORD ou PBS_PASSWORD_FILE doit être défini dans le conf"
        exit 1
    fi

    check_success=0
    check_output=""
    if [[ "$PBS_CLIENT_MODE" == "docker" ]]; then
        check_output=$(docker run --rm --network host \
            ${PBS_FINGERPRINT:+-e "PBS_FINGERPRINT=${PBS_FINGERPRINT}"} \
            ${PBS_PASSWORD:+-e "PBS_PASSWORD=${PBS_PASSWORD}"} \
            ${PBS_PASSWORD_FILE:+-e "PBS_PASSWORD_FILE=${PBS_PASSWORD_FILE}"} \
            "$PBS_DOCKER_IMAGE" list --repository "$PBS_REPOSITORY_FULL" ${EFFECTIVE_PBS_NAMESPACE:+--ns "$EFFECTIVE_PBS_NAMESPACE"} 2>&1) && check_success=1
    else
        check_output=$(env ${PBS_FINGERPRINT:+PBS_FINGERPRINT="$PBS_FINGERPRINT"} \
            ${PBS_PASSWORD:+PBS_PASSWORD="$PBS_PASSWORD"} \
            ${PBS_PASSWORD_FILE:+PBS_PASSWORD_FILE="$PBS_PASSWORD_FILE"} \
            proxmox-backup-client list --repository "$PBS_REPOSITORY_FULL" ${EFFECTIVE_PBS_NAMESPACE:+--ns "$EFFECTIVE_PBS_NAMESPACE"} 2>&1) && check_success=1
    fi

    echo -e "\n--- Résultat du test PBS ---"
    echo "$check_output"
    if [[ $check_success -eq 1 ]]; then
        log "INFO" "Connexion à PBS OK."
        exit 0
    else
        log "ERROR" "Échec de connexion à PBS. Voir $LOG_FILE pour les détails."
        exit 2
    fi
fi

if [[ $# -lt 2 ]]; then
    usage
    exit 1
fi

BACKUP_NAME="$1"
shift

# PBS_BACKUP_ID est dérivé du nom de backup si non défini
PBS_BACKUP_ID="${PBS_BACKUP_ID:-$BACKUP_NAME}"

# Defaults
# Nom de log suffixé par le nom du backup (sanitisé)
SAFE_BACKUP_NAME="$(sanitize_name "$BACKUP_NAME")"
# Fichier de log par défaut dans un sous-répertoire 'logs' du script
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/logs/backup_${SAFE_BACKUP_NAME}.log}"
# S'assurer que le répertoire de logs existe
mkdir -p "$(dirname "$LOG_FILE")"
PBS_CLIENT_MODE="${PBS_CLIENT_MODE:-apt}"
PBS_BACKUP_TYPE="${PBS_BACKUP_TYPE:-host}"
PBS_DOCKER_IMAGE="${PBS_DOCKER_IMAGE:-proxmox-pbs-client:latest}"
PBS_CHANGE_DETECTION_MODE="${PBS_CHANGE_DETECTION_MODE:-}"
PBS_CLIENT_EXTRA_ARGS="${PBS_CLIENT_EXTRA_ARGS:-}"

# MQTT / Home Assistant
MQTT_ENABLED="${MQTT_ENABLED:-false}"
MQTT_HOST="${MQTT_HOST:-localhost}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASSWORD="${MQTT_PASSWORD:-}"

MQTT_DEVICE_TOPIC="homeassistant/device/backup/${PBS_BACKUP_ID}/config"
MQTT_STATE_TOPIC="backup/${PBS_BACKUP_ID}/state"

BACKUP_STATUS="running"
START_TIME=$(date +%s)
BACKUP_DURATION=0
ERROR_MESSAGE=""
BACKUP_DATE=$(date +"%Y%m%d%H%M")


# Nouvelle logique : un seul répertoire à sauvegarder (-d), exclusions multiples (-e)
BACKUP_DIR=""
EXCLUDES=()
PBS_DATASTORE="${PBS_DATASTORE_DEFAULT:-}" # datastore par défaut
if [[ -z "$PBS_DATASTORE" ]]; then
    PBS_DATASTORE="backup" # fallback si non défini
fi
PBS_DATASTORE_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)
            shift
            if [[ -z "${1:-}" ]]; then
                log "ERROR" "-d requiert un chemin"
                exit 1
            fi
            if [[ -n "$BACKUP_DIR" ]]; then
                log "ERROR" "Un seul répertoire -d est autorisé."
                exit 1
            fi
            BACKUP_DIR="$1"
            ;;
        -e)
            shift
            if [[ -z "${1:-}" ]]; then
                log "ERROR" "-e requiert un chemin"
                exit 1
            fi
            EXCLUDES+=("$1")
            ;;
        --datastore)
            shift
            if [[ -z "${1:-}" ]]; then
                log "ERROR" "--datastore requiert un nom de datastore"
                exit 1
            fi
            PBS_DATASTORE_ARG="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log "ERROR" "Argument inconnu ou non supporté : $1"
            usage
            exit 1
            ;;
    esac
    shift
done

if [[ -z "$BACKUP_DIR" ]]; then
    log "ERROR" "Aucun répertoire à sauvegarder (-d) fourni."
    usage
    exit 1
fi
if [[ ! -d "$BACKUP_DIR" ]]; then
    log "ERROR" "Répertoire à sauvegarder introuvable : $BACKUP_DIR"
    exit 1
fi

extra_args=()
if [[ -n "$PBS_CHANGE_DETECTION_MODE" ]]; then
    extra_args+=(--change-detection-mode "$PBS_CHANGE_DETECTION_MODE")
fi
if [[ -n "$PBS_CLIENT_EXTRA_ARGS" ]]; then
    read -r -a extra_user_args <<< "$PBS_CLIENT_EXTRA_ARGS"
    extra_args+=("${extra_user_args[@]}")
fi
for ex in "${EXCLUDES[@]}"; do
    extra_args+=(--exclude "$ex")
done

require_var PBS_REPOSITORY
# PBS_PASSWORD ou PBS_PASSWORD_FILE sont attendus par proxmox-backup-client
if [[ -z "${PBS_PASSWORD:-}" && -z "${PBS_PASSWORD_FILE:-}" ]]; then
    log "ERROR" "PBS_PASSWORD ou PBS_PASSWORD_FILE doit être défini dans le conf"
    exit 1
fi

# Construction de la chaîne PBS_REPOSITORY complète avec le datastore
if [[ -n "$PBS_DATASTORE_ARG" ]]; then
    PBS_REPOSITORY_FULL="$PBS_REPOSITORY:$PBS_DATASTORE_ARG"
else
    PBS_REPOSITORY_FULL="$PBS_REPOSITORY:$PBS_DATASTORE"
fi

# Vérification de la longueur du mot de passe
if [[ -n "${PBS_PASSWORD:-}" && ${#PBS_PASSWORD} -le 40 ]]; then
    log "ERROR" "PBS_PASSWORD trop court : ${#PBS_PASSWORD} caractères (minimum 41)"
    echo "ERREUR: PBS_PASSWORD doit faire plus de 40 caractères pour la sécurité." >&2
    exit 1
fi

publish_mqtt_discovery() {
    if [[ "$MQTT_ENABLED" != "true" ]]; then
        return 0
    fi

    local device_config
    device_config='{
        "device": {
            "identifiers": ["backup_'"$BACKUP_NAME"'"],
            "name": "'"$BACKUP_NAME"' Backup Monitor",
            "model": "PBS Backup Script",
            "manufacturer": "Custom Script",
            "sw_version": "1.0.0"
        },
        "origin": {
            "name": "PBS Backup Script"
        },
        "state_topic": "'"$MQTT_STATE_TOPIC"'",
        "components": {
            "pbs_backup_status": {
                "platform": "sensor",
                "unique_id": "backup_'"$BACKUP_NAME"'_status",
                "default_entity_id": "sensor.backup_'"$BACKUP_NAME"'_status",
                "has_entity_name": true,
                "force_update": true,
                "name": "Status",
                "icon": "mdi:cloud-check",
                "availability_mode": "all",
                "value_template": "{{ value_json.status }}"
            },
            "pbs_backup_duration": {
                "platform": "sensor",
                "unique_id": "backup_'"$BACKUP_NAME"'_duration",
                "default_entity_id": "sensor.backup_'"$BACKUP_NAME"'_duration",
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
            "pbs_backup_last_run": {
                "platform": "sensor",
                "unique_id": "backup_'"$BACKUP_NAME"'_last_run",
                "default_entity_id": "sensor.backup_'"$BACKUP_NAME"'_last_run",
                "has_entity_name": true,
                "force_update": true,
                "name": "Last Backup",
                "icon": "mdi:clock-outline",
                "availability_mode": "all",
                "value_template": "{{ as_datetime(value_json.last_backup_timestamp) }}",
                "device_class": "timestamp"
            },
            "pbs_backup_problem": {
                "platform": "binary_sensor",
                "unique_id": "backup_'"$BACKUP_NAME"'_problem",
                "default_entity_id": "binary_sensor.backup_'"$BACKUP_NAME"'_problem",
                "has_entity_name": true,
                "force_update": true,
                "name": "Backup Problem",
                "icon": "mdi:alert-circle",
                "availability_mode": "all",
                "value_template": "{{ \"failed\" if value_json.status in [\"failed\"] else \"success\" }}",
                "device_class": "problem",
                "payload_on": "failed",
                "payload_off": "success"
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

    local current_timestamp
    current_timestamp=$(date -Iseconds)

    local payload
    payload="{\"status\":\"$BACKUP_STATUS\",\"duration\":$BACKUP_DURATION,\"backup_name\":\"$BACKUP_NAME\",\"last_backup_timestamp\":\"$current_timestamp\",\"error_message\":\"$ERROR_MESSAGE\",\"backup_date\":\"$BACKUP_DATE\"}"

    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        ${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASSWORD:+-P "$MQTT_PASSWORD"} \
        -t "$MQTT_STATE_TOPIC" -m "$payload" -r 2>/dev/null || true
}

cleanup() {
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        BACKUP_STATUS="failed"
        ERROR_MESSAGE="Script interrompu avec le code d'erreur: $exit_code"
    fi

    BACKUP_DURATION=$(($(date +%s) - START_TIME))
    publish_metrics
    exit $exit_code
}

trap cleanup EXIT

log "INFO" "Démarrage backup: name='${BACKUP_NAME}', mode='${PBS_CLIENT_MODE}'"
publish_mqtt_discovery


# Préparation du mapping pxar unique et du montage si docker
specs=()
mounts=()
base_name="$(basename "$BACKUP_DIR")"
safe_name="$(sanitize_name "$base_name")"
if [[ -z "$safe_name" ]]; then
    safe_name="data"
fi
if [[ "$PBS_CLIENT_MODE" == "docker" ]]; then
    mount_target="/source"
    mounts+=("--volume" "${BACKUP_DIR}:${mount_target}:ro")
    specs+=("${safe_name}.pxar:${mount_target}")
    log "INFO" "Mapping docker: ${BACKUP_DIR} -> ${mount_target} (archive ${safe_name}.pxar)"
else
    specs+=("${safe_name}.pxar:${BACKUP_DIR}")
fi

run_client_apt() {
    log "INFO" "Exécution proxmox-backup-client (apt)"
    local -a env_vars=()
    env_vars+=("PBS_FINGERPRINT=${PBS_FINGERPRINT:-}")
    if [[ -n "${PBS_PASSWORD:-}" ]]; then
        env_vars+=("PBS_PASSWORD=${PBS_PASSWORD}")
    fi
    if [[ -n "${PBS_PASSWORD_FILE:-}" ]]; then
        env_vars+=("PBS_PASSWORD_FILE=${PBS_PASSWORD_FILE}")
    fi

    env "${env_vars[@]}" proxmox-backup-client backup \
        "${specs[@]}" \
        --repository "$PBS_REPOSITORY_FULL" \
        --backup-id "$BACKUP_NAME" \
        --backup-type "$PBS_BACKUP_TYPE" \
        ${PBS_NAMESPACE:+--ns "$PBS_NAMESPACE"} \
        "${extra_args[@]}"
}

run_client_docker() {
    log "INFO" "Exécution proxmox-backup-client (docker)"

    local -a pbs_args=(
        backup
        "${specs[@]}"
        --backup-id "$BACKUP_NAME"
        --backup-type "$PBS_BACKUP_TYPE"
        ${PBS_NAMESPACE:+--ns "$PBS_NAMESPACE"}
        --repository "$PBS_REPOSITORY_FULL"
        "${extra_args[@]}"
    )

    docker run --rm --network host \
        "${mounts[@]}" \
        -e "PBS_REPOSITORY=${PBS_REPOSITORY_FULL}" \
        ${PBS_PASSWORD:+-e "PBS_PASSWORD=${PBS_PASSWORD}"} \
        ${PBS_PASSWORD_FILE:+-e "PBS_PASSWORD_FILE=${PBS_PASSWORD_FILE}"} \
        ${PBS_FINGERPRINT:+-e "PBS_FINGERPRINT=${PBS_FINGERPRINT}"} \
        "$PBS_DOCKER_IMAGE" \
        "${pbs_args[@]}" \
        2>>"$LOG_FILE"
}

case "$PBS_CLIENT_MODE" in
    apt)
        run_client_apt
        ;;
    docker)
        # Vérification automatique de l'image Docker
        if ! docker image inspect "$PBS_DOCKER_IMAGE" > /dev/null 2>&1; then
                log "INFO" "Image $PBS_DOCKER_IMAGE absente, lancement du build..."
                "$REPO_ROOT/pbs_client/build_pbs_client.sh"
        fi
        run_client_docker
        ;;
    *)
        log "ERROR" "PBS_CLIENT_MODE invalide: $PBS_CLIENT_MODE (apt|docker)"
        exit 1
        ;;
esac

    BACKUP_STATUS="success"
    log "INFO" "Backup terminé avec succès"
