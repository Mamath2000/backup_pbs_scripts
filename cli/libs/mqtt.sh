#!/usr/bin/env bash

mqtt::publish_discovery() {
    [[ "$MQTT_ENABLED" != "true" ]] && return 0

    local id="$PBS_BACKUP_ID"
    local name="$BACKUP_NAME"
    local device_topic="homeassistant/device/backup/${id}/config"
    local state_topic="backup/${id}/state"

    MQTT_STATE_TOPIC="$state_topic"

    jq -n \
        --arg id "$id" \
        --arg name "$name" \
        --arg topic "$state_topic" \
        '
        {
            device: {
                identifiers: ["backup_" + $id],
                name: ($name + " Backup Monitor"),
                model: "PBS Backup Script",
                manufacturer: "Custom Script",
                sw_version: "1.0.0"
            },
            origin: { name: "PBS Backup Script" },
            state_topic: $topic,
            components: {
                ("pbs_backup_status"): {
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
                ("pbs_backup_duration"): {
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
                ("pbs_backup_last_run"): {
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
                ("pbs_backup_problem"): {
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
        ' \
    | mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        ${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASSWORD:+-P "$MQTT_PASSWORD"} \
        -t "$device_topic" -s -r 2>/dev/null || true
}

mqtt::publish_metrics() {
    [[ "$MQTT_ENABLED" != "true" ]] && return 0

    local ts
    ts=$(date -Iseconds)

    jq -n \
        --arg status "${BACKUP_STATUS:-unknown}" \
        --arg duration "${BACKUP_DURATION:-0}" \
        --arg name "$BACKUP_NAME" \
        --arg ts "$ts" \
        --arg err "${ERROR_MESSAGE:-}" \
        --arg date "${BACKUP_DATE:-}" \
        '
        {
            status: $status,
            duration: ($duration | tonumber),
            backup_name: $name,
            last_backup_timestamp: $ts,
            error_message: $err,
            backup_date: $date
        }
        ' \
    | mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        ${MQTT_USER:+-u "$MQTT_USER"} ${MQTT_PASSWORD:+-P "$MQTT_PASSWORD"} \
        -t "$MQTT_STATE_TOPIC" -s -r 2>/dev/null || true
}
