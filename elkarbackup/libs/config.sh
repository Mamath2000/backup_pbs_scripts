#!/usr/bin/env bash

config::load() {
    local file="$1"
    local mode="$2"
    local dir="$3"
    local repo_root="$4"

    if [[ ! -f "$file" ]]; then
        echo "ERREUR: Fichier de configuration non trouvé: $file"
        [[ "$mode" != "check" ]] && rm -f "$dir/.backup_elkarbackup.lock"
        exit 1
    fi

    source "$file"

    PBS_DATASTORE="${PBS_DATASTORE_DEFAULT:-backup}"
    [[ -n "$PBS_DATASTORE_ARG" ]] && PBS_DATASTORE="$PBS_DATASTORE_ARG"

    PBS_REPOSITORY_FULL="${PBS_REPOSITORY}:${PBS_DATASTORE}"

    PBS_CLIENT_MODE="${PBS_CLIENT_MODE:-docker}"

    MQTT_ENABLED="${MQTT_ENABLED:-false}"
    MQTT_PORT="${MQTT_PORT:-1883}"
    MQTT_USER="${MQTT_USER:-}"
    MQTT_PASSWORD="${MQTT_PASSWORD:-}"

    TEST_MODE=false
    [[ "$mode" == "dummy-run" ]] && TEST_MODE=true

    START_TIME=$(date +%s)
    BACKUP_DATE=$(date +"%Y%m%d%H%M")

    BACKUP_STATUS="unknown"
    BACKUP_DURATION=0
    TOTAL_BACKUP_SIZE=0
    TOTAL_COMPRESSED_SIZE=0
    COMPRESSION_RATIO=0
    ERROR_MESSAGE=""
    BACKUP_FILES=()

    REPO_ROOT="$repo_root"
}
