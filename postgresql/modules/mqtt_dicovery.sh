mqtt::publish_mqtt_discovery() {
    # usage: mqtt::publish_mqtt_discovery <backup_id> [display_name]
    local backup_id="$1"
    local display_name="${2:-}"
    if [[ -z "$backup_id" ]]; then
        logs::error "mqtt::publish_mqtt_discovery: backup_id manquant"
        return 1
    fi
    if [[ -z "$display_name" ]]; then
        logs::error "mqtt::publish_mqtt_discovery: display_name manquant"
        return 1
    fi    
    if [[ "${MQTT_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    logs::debug "Publication discovery MQTT pour: $backup_id"

    local device_topic
    device_topic=$(printf '%s' "homeassistant/device/backup/${backup_id}/config" | tr '[:upper:]' '[:lower:]')
    local state_topic
    state_topic=$(printf '%s' "${MQTT_BASE_TOPIC:-backup}/${backup_id}/state" | tr '[:upper:]' '[:lower:]')
    local name_field
    name_field="PostgreSQL Backup ($display_name)"
    local id_field
    id_field="postgres_backup_$backup_id"

    local device_config
    device_config='{
        "device": {
            "identifiers": ["'$id_field'"],
            "name": "'$name_field'",
            "model": "PostgreSQL Backup Script",
            "manufacturer": "Custom Script",
            "sw_version": "2.0.0"},
        "origin":{"name": "PostgreSQL Backup Script"},
        "state_topic": "'$state_topic'",
        "components": {
            "'$id_field'_status": {
                "platform": "sensor",
                "unique_id": "backup_'$id_field'_status",
                "default_entity_id": "sensor.backup_'$id_field'_status",
                "has_entity_name": true,
                "force_update": true,
                "name": "Status",
                "icon": "mdi:cloud-check",
                "availability_mode": "all",
                "value_template": "{{ value_json.status }}"
            },
            "'$id_field'_duration": {
                "platform": "sensor",
                "unique_id": "backup_'$id_field'_duration",
                "default_entity_id": "sensor.backup_'$id_field'_duration",
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
            "'$id_field'_last_run": {
                "platform": "sensor",
                "unique_id": "backup_'$id_field'_last_run",
                "default_entity_id": "sensor.backup_'$id_field'_last_run",
                "has_entity_name": true,
                "force_update": true,
                "name": "Last Backup",
                "icon": "mdi:clock-outline",
                "availability_mode": "all",
                "value_template": "{{ as_datetime(value_json.last_backup_timestamp) }}",
                "device_class": "timestamp"
            },
            "'$id_field'_problem": {
                "platform": "binary_sensor",
                "unique_id": "backup_'$id_field'_problem",
                "default_entity_id": "binary_sensor.backup_'$id_field'_problem",
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
        -t "$device_topic" -m "$device_config" -r 2>/dev/null || true
}

mqtt::publish_metrics() {
    # usage: mqtt::publish_metrics [backup_id]
    if [[ "$MQTT_ENABLED" != "true" ]]; then
        return 0
    fi
    logs::debug "Publication des métriques MQTT unifiées"

    local publish_id
    publish_id="${1:-${PBS_BACKUP_ID:-}}"
    if [[ -z "$publish_id" ]]; then
        local host
        host=$(hostname -s 2>/dev/null || hostname)
        host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
        publish_id="${host}_full"
        if [[ "${TEST_MODE:-false}" == "true" ]]; then
            publish_id="test_${publish_id}"
        fi
    fi

    local current_timestamp
    current_timestamp=$(date -Iseconds)

    local state_topic
    state_topic=$(printf '%s' "${MQTT_BASE_TOPIC:-backup}/${publish_id}/state" | tr '[:upper:]' '[:lower:]')

    local pbs_enabled_bool
    pbs_enabled_bool=$( [ "${PBS_ENABLED:-false}" = "true" ] && echo true || echo false )
    local pbs_ok_bool
    pbs_ok_bool=$( [ "${PBS_OK:-false}" = "true" ] && echo true || echo false )
    local test_mode_bool
    test_mode_bool=$( [ "${TEST_MODE:-false}" = "true" ] && echo true || echo false )

    local json='{
        "status":"%s",
        "duration":%s,
        "size_mb":%s,
        "compression_ratio":%s,
        "backup_file":"%s",
        "last_backup_timestamp":"%s",
        "error_message":"%s",
        "backup_date":"%s",
        "pbs_enabled":%s,
        "pbs_status":"%s"}'

    local unified_payload
    unified_payload=`printf "$json" "$BACKUP_STATUS" "${BACKUP_DURATION:-0}" "${BACKUP_SIZE:-0}" "${COMPRESSION_RATIO:-0}" "${BACKUP_FILE_COMPRESSED:-}" \
        "$current_timestamp" "${ERROR_MESSAGE:-}" "${BACKUP_DATE:-}" \
        "$pbs_enabled_bool" "${PBS_STATUS:-}"`

    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        ${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASSWORD:+-P "$MQTT_PASSWORD"} \
        -t "$state_topic" -m "$unified_payload" -r 2>/dev/null || true

    logs::debug "Métriques publiées sur: $state_topic"

}