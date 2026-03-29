mqtt::init_backup() {
    local id="$1"
    local name="$2"
    mqtt::publish_mqtt_discovery "$id" "$name"
}

mqtt::finalize_backup() {
    local id="$1"
    mqtt::publish_metrics "$id"
}

mqtt::publish_mqtt_discovery() {
    # usage: mqtt::publish_mqtt_discovery <backup_id> [display_name]
    local backup_id="$1"
    local display_name="$2"

    [[ -z "$backup_id" ]] && logs::error "backup_id manquant" && return 1
    [[ -z "$display_name" ]] && logs::error "display_name manquant" && return 1
    [[ "${MQTT_ENABLED:-false}" != "true" ]] && return 0

    logs::debug "Publication discovery MQTT pour: $backup_id"

    local device_topic
    device_topic=$(printf '%s' "homeassistant/device/backup/${backup_id}/config" | tr '[:upper:]' '[:lower:]')

    local state_topic
    state_topic=$(printf '%s' "${MQTT_BASE_TOPIC:-backup}/${backup_id}/state" | tr '[:upper:]' '[:lower:]')

    local name_field="PostgreSQL Backup ($display_name)"
    local id_field="postgres_backup_${backup_id}"

    # Construction JSON via jq (obligatoire)
    local payload
    payload=$(json::build_discovery_payload "$id_field" "$name_field" "$state_topic")

    local mqtt_out
    if mqtt_out=$(mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        ${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASSWORD:+-P "$MQTT_PASSWORD"} \
        -t "$device_topic" -m "$payload" -r 2>&1); then
        logs::debug "MQTT discovery publié: $device_topic"
    else
        local mqtt_redacted
        mqtt_redacted=$(printf '%s' "$mqtt_out" | sed -E 's/(MQTT_PASSWORD=)[^[:space:]]+/\1***/g')
        logs::error "Échec publication MQTT discovery: $mqtt_redacted"
        printf '%s\n' "$mqtt_redacted" >>"$LOG_FILE" 2>&1
    fi
}

mqtt::publish_metrics() {
    [[ "${MQTT_ENABLED:-false}" != "true" ]] && return 0

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

    # Booléens normalisés
    local pbs_enabled_bool=$([[ "${PBS_ENABLED:-false}" == "true" ]] && echo true || echo false)
    local pbs_status="${PBS_STATUS:-}"

    # Construction JSON via jq (obligatoire)
    local payload
    payload=$(json::build_metrics_payload \
        "${BACKUP_STATUS:-unknown}" \
        "${BACKUP_DURATION:-0}" \
        "${BACKUP_SIZE:-0}" \
        "${COMPRESSION_RATIO:-0}" \
        "${BACKUP_FILE_COMPRESSED:-}" \
        "$current_timestamp" \
        "${ERROR_MESSAGE:-}" \
        "${BACKUP_DATE:-}" \
        "$pbs_enabled_bool" \
        "$pbs_status"
    )

    local mqtt_out
    if mqtt_out=$(mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        ${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASSWORD:+-P "$MQTT_PASSWORD"} \
        -t "$state_topic" -m "$payload" -r 2>&1); then
        logs::debug "Métriques MQTT publiées sur: $state_topic"
    else
        local mqtt_redacted
        mqtt_redacted=$(printf '%s' "$mqtt_out" | sed -E 's/(MQTT_PASSWORD=)[^[:space:]]+/\1***/g')
        logs::error "Échec publication MQTT metrics: $mqtt_redacted"
        printf '%s\n' "$mqtt_redacted" >>"$LOG_FILE" 2>&1
    fi
}


json::build_discovery_payload() { 
    local id_field="$1"
    local name_field="$2"
    local state_topic="$3"

    jq -n \
        --arg id "$id_field" \
        --arg name "$name_field" \
        --arg state "$state_topic" \
        '
        {
            device: {
                identifiers: [$id],
                name: $name,
                model: "PostgreSQL Backup Script",
                manufacturer: "Custom Script",
                sw_version: "2.0.0"
            },
            origin: { name: "PostgreSQL Backup Script" },
            state_topic: $state,
            components: {
                ($id + "_status"): {
                    platform: "sensor",
                    unique_id: ("backup_" + $id + "_status"),
                    default_entity_id: ("sensor.backup_" + $id + "_status"),
                    has_entity_name: true,
                    force_update: true,
                    name: "Status",
                    icon: "mdi:cloud-check",
                    availability_mode: "all",
                    value_template: "{{ value_json.status }}"
                },
                ($id + "_duration"): {
                    platform: "sensor",
                    unique_id: ("backup_" + $id + "_duration"),
                    default_entity_id: ("sensor.backup_" + $id + "_duration"),
                    has_entity_name: true,
                    force_update: true,
                    name: "Duration",
                    icon: "mdi:timer-outline",
                    availability_mode: "all",
                    value_template: "{{ value_json.duration }}",
                    device_class: "duration",
                    unit_of_measurement: "s",
                    state_class: "measurement"
                },
                ($id + "_last_run"): {
                    platform: "sensor",
                    unique_id: ("backup_" + $id + "_last_run"),
                    default_entity_id: ("sensor.backup_" + $id + "_last_run"),
                    has_entity_name: true,
                    force_update: true,
                    name: "Last Backup",
                    icon: "mdi:clock-outline",
                    availability_mode: "all",
                    value_template: "{{ as_datetime(value_json.last_backup_timestamp) }}",
                    device_class: "timestamp"
                },
                ($id + "_problem"): {
                    platform: "binary_sensor",
                    unique_id: ("backup_" + $id + "_problem"),
                    default_entity_id: ("binary_sensor.backup_" + $id + "_problem"),
                    has_entity_name: true,
                    force_update: true,
                    name: "Backup Problem",
                    icon: "mdi:alert-circle",
                    availability_mode: "all",
                    value_template: "{{ \"failed\" if value_json.status == \"failed\" else \"success\" }}",
                    device_class: "problem",
                    payload_on: "failed",
                    payload_off: "success"
                }
            }
        }
        '
}

json::build_metrics_payload() {
    local backup_status="$1"
    local backup_duration="$2"
    local backup_size="$3"
    local compression_ratio="$4"
    local backup_file="$5"
    local timestamp="$6"
    local error_message="$7"
    local backup_date="$8"
    local pbs_enabled="$9"
    local pbs_status="${10}"

    jq -n \
        --arg status "$backup_status" \
        --arg duration "$backup_duration" \
        --arg size_mb "$backup_size" \
        --arg ratio "$compression_ratio" \
        --arg file "$backup_file" \
        --arg ts "$timestamp" \
        --arg err "$error_message" \
        --arg date "$backup_date" \
        --arg pbs_enabled "$pbs_enabled" \
        --arg pbs_status "$pbs_status" \
        '
        {
            status: $status,
            duration: ($duration | tonumber),
            size_mb: ($size_mb | tonumber),
            compression_ratio: ($ratio | tonumber),
            backup_file: $file,
            last_backup_timestamp: $ts,
            error_message: $err,
            backup_date: $date,
            pbs_enabled: ($pbs_enabled == "true"),
            pbs_status: $pbs_status
        }
        '
}
