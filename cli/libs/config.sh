#!/usr/bin/env bash

config::load() {
    CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERREUR: Fichier de configuration introuvable: $CONFIG_FILE" >&2
        exit 1
    fi

    local conf_perm
    conf_perm=$(stat -c "%a" "$CONFIG_FILE")
    if [[ "$conf_perm" != "600" ]]; then
        echo "ERREUR: Les droits sur $CONFIG_FILE doivent être 600 (actuellement $conf_perm)" >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    require_var PBS_REPOSITORY
    PBS_CLIENT_MODE="${PBS_CLIENT_MODE:-apt}"
    PBS_DOCKER_IMAGE="${PBS_DOCKER_IMAGE:-proxmox-pbs-client:latest}"
    PBS_BACKUP_TYPE="${PBS_BACKUP_TYPE:-host}"
    PBS_DATASTORE_DEFAULT="${PBS_DATASTORE_DEFAULT:-backup}"

    if [[ -z "${PBS_PASSWORD:-}" && -z "${PBS_PASSWORD_FILE:-}" ]]; then
        logs::error "PBS_PASSWORD ou PBS_PASSWORD_FILE doit être défini dans la conf"
        exit 1
    fi

    if [[ -n "${PBS_PASSWORD:-}" && ${#PBS_PASSWORD} -le 40 ]]; then
        logs::error "PBS_PASSWORD trop court : ${#PBS_PASSWORD} caractères (minimum 41)"
        exit 1
    fi

    MQTT_ENABLED="${MQTT_ENABLED:-false}"
    MQTT_HOST="${MQTT_HOST:-localhost}"
    MQTT_PORT="${MQTT_PORT:-1883}"
    MQTT_USER="${MQTT_USER:-}"
    MQTT_PASSWORD="${MQTT_PASSWORD:-}"
}
