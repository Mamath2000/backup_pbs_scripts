#!/usr/bin/env bash

mqtt::publish_discovery() {
    if [[ "$MQTT_ENABLED" != "true" ]]; then
        return 0
    fi

    log::debug "Publication de la déclaration de device MQTT"

    # Configuration du device avec tous les composants
    local device_config='{
        "device": {
            "identifiers": ["elkarbackup_monitor"],
            "name": "Backup Elkarbackup Monitor",
            "model": "Backup Script",
            "manufacturer": "Custom Script",
            "sw_version": "2.0.0"
        },
        "origin": {
            "name": "ElkarBackup Script"
        },
        "state_topic": "'$MQTT_STATE_TOPIC'",
        "components": {
            "elkarbackup_status": {
                "platform": "sensor",
                "unique_id": "elkarbackup_status",
                "object_id": "elkarbackup_status",
                "has_entity_name": true,
                "force_update": true,
                "name": "Status",
                "icon": "mdi:database-check",
                "availability_mode": "all",
                "value_template": "{{ value_json.status }}",
                "device_class": null,
                "state_class": null
            },
            "elkarbackup_duration": {
                "platform": "sensor",
                "unique_id": "elkarbackup_duration",
                "object_id": "elkarbackup_duration",
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
            "elkarbackup_size": {
                "platform": "sensor",
                "unique_id": "elkarbackup_size",
                "object_id": "elkarbackup_size",
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
            "elkarbackup_compression": {
                "platform": "sensor",
                "unique_id": "elkarbackup_compression",
                "object_id": "elkarbackup_compression",
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
            "elkarbackup_last_run": {
                "platform": "sensor",
                "unique_id": "elkarbackup_last_run",
                "object_id": "elkarbackup_last_run",
                "has_entity_name": true,
                "force_update": true,
                "name": "Last Backup",
                "icon": "mdi:clock-outline",
                "availability_mode": "all",
                "value_template": "{{ as_datetime(value_json.last_backup_timestamp) }}",
                "device_class": "timestamp"
            },
            "elkarbackup_problem": {
                "platform": "binary_sensor",
                "unique_id": "elkarbackup_problem",
                "object_id": "elkarbackup_problem",
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

mqtt::publish_metrics() {
    if [[ "$MQTT_ENABLED" != "true" ]]; then
        return 0
    fi

    log::debug "Publication des métriques MQTT unifiées"

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
            \"databases\": \"$(IFS=,; echo "${DB_NAMES[*]}")\",
            \"docker_container\": \"$DOCKER_CONTAINER_NAME\"
        }"

    # Publication du payload unifié sur le topic unique
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        ${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASSWORD:+-P "$MQTT_PASSWORD"} \
        -t "$MQTT_STATE_TOPIC" -m "$unified_payload" 2>/dev/null || true

    log::debug "Métriques publiées sur: $MQTT_STATE_TOPIC"
}