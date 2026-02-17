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
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERREUR: Fichier de configuration introuvable: $CONFIG_FILE" >&2
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
Usage: $(basename "$0") "nom-backup" [-d /chemin]... [-e /chemin]... [/chemin...]

Exemples:
    $(basename "$0") host-prod /etc /var/lib/app
    $(basename "$0") host-prod -d /etc -d /var/lib/app -e /var/lib/app/cache
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


# Mode test de connexion : ./backup_pbs.sh --check
if [[ "${1:-}" == "--check" ]]; then
    log "INFO" "Mode test de connexion à PBS activé."
    require_var PBS_REPOSITORY
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
            "$PBS_DOCKER_IMAGE" list --repository "$PBS_REPOSITORY" 2>&1) && check_success=1
    else
        check_output=$(env ${PBS_FINGERPRINT:+PBS_FINGERPRINT="$PBS_FINGERPRINT"} \
            ${PBS_PASSWORD:+PBS_PASSWORD="$PBS_PASSWORD"} \
            ${PBS_PASSWORD_FILE:+PBS_PASSWORD_FILE="$PBS_PASSWORD_FILE"} \
            proxmox-backup-client list --repository "$PBS_REPOSITORY" 2>&1) && check_success=1
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
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/backup.log}"
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

DIRS=()
EXCLUDES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)
            shift
            if [[ -z "${1:-}" ]]; then
                log "ERROR" "-d requiert un chemin"
                exit 1
            fi
            DIRS+=("$1")
            ;;
        -e)
            shift
            if [[ -z "${1:-}" ]]; then
                log "ERROR" "-e requiert un chemin"
                exit 1
            fi
            EXCLUDES+=("$1")
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            DIRS+=("$1")
            ;;
    esac
    shift
done

if [[ ${#DIRS[@]} -lt 1 ]]; then
    log "ERROR" "Aucun répertoire fourni"
    usage
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

# Préparation des specs (pxar) et montages si docker
specs=()
mounts=()
used_names=()
idx=0

for path in "${DIRS[@]}"; do
    if [[ ! -d "$path" ]]; then
        log "ERROR" "Répertoire introuvable: $path"
        exit 1
    fi
    idx=$((idx + 1))
    base_name="$(basename "$path")"
    safe_name="$(sanitize_name "$base_name")"
    if [[ -z "$safe_name" ]]; then
        safe_name="dir${idx}"
    fi

    # Eviter les doublons de noms d'archives
    final_name="$safe_name"
    for existing in "${used_names[@]:-}"; do
        if [[ "$existing" == "$final_name" ]]; then
            final_name="${safe_name}_${idx}"
            break
        fi
    done
    used_names+=("$final_name")

    if [[ "$PBS_CLIENT_MODE" == "docker" ]]; then
        mount_target="/source${idx}"
        mounts+=("--volume" "${path}:${mount_target}:ro")
        specs+=("${final_name}.pxar:${mount_target}")
        log "INFO" "Mapping docker: ${path} -> ${mount_target} (archive ${final_name}.pxar)"
    else
        specs+=("${final_name}.pxar:${path}")
    fi

done

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
        --repository "$PBS_REPOSITORY" \
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
        --repository "$PBS_REPOSITORY"
        "${extra_args[@]}"
    )

    docker run --rm --network host \
        "${mounts[@]}" \
        -e "PBS_REPOSITORY=${PBS_REPOSITORY}" \
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
        run_client_docker
        ;;
    *)
        log "ERROR" "PBS_CLIENT_MODE invalide: $PBS_CLIENT_MODE (apt|docker)"
        exit 1
        ;;
esac

    BACKUP_STATUS="success"
    log "INFO" "Backup terminé avec succès"
