#!/usr/bin/env bash

pbs::build_repository_full() {
    local datastore="${PBS_DATASTORE_ARG:-${PBS_DATASTORE_DEFAULT:-backup}}"
    PBS_REPOSITORY_FULL="${PBS_REPOSITORY}:${datastore}"
}

pbs::build_specs() {
    SPECS=()
    MOUNTS=()

    local base_name
    base_name="$(basename "$BACKUP_DIR")"
    local safe_name
    safe_name="$(sanitize_name "$base_name")"
    [[ -z "$safe_name" ]] && safe_name="data"

    if [[ "$PBS_CLIENT_MODE" == "docker" ]]; then
        local mount_target="/source"
        MOUNTS+=("--volume" "${BACKUP_DIR}:${mount_target}:ro")
        SPECS+=("${safe_name}.pxar:${mount_target}")
    else
        SPECS+=("${safe_name}.pxar:${BACKUP_DIR}")
    fi
}

pbs::run_apt() {
    logs::info "Exécution proxmox-backup-client (apt)"

    local -a env_vars=()
    [[ -n "${PBS_FINGERPRINT:-}" ]] && env_vars+=("PBS_FINGERPRINT=${PBS_FINGERPRINT}")
    [[ -n "${PBS_PASSWORD:-}" ]] && env_vars+=("PBS_PASSWORD=${PBS_PASSWORD}")
    [[ -n "${PBS_PASSWORD_FILE:-}" ]] && env_vars+=("PBS_PASSWORD_FILE=${PBS_PASSWORD_FILE}")

    env "${env_vars[@]}" proxmox-backup-client backup \
        "${SPECS[@]}" \
        --repository "$PBS_REPOSITORY_FULL" \
        --backup-id "$BACKUP_NAME" \
        --backup-type "$PBS_BACKUP_TYPE" \
        ${PBS_NAMESPACE:+--ns "$PBS_NAMESPACE"} \
        "${EXTRA_ARGS[@]}"
}

pbs::run_docker() {
    logs::info "Exécution proxmox-backup-client (docker)"

    local -a pbs_args=(
        backup
        "${SPECS[@]}"
        --backup-id "$BACKUP_NAME"
        --backup-type "$PBS_BACKUP_TYPE"
        ${PBS_NAMESPACE:+--ns "$PBS_NAMESPACE"}
        --repository "$PBS_REPOSITORY_FULL"
        "${EXTRA_ARGS[@]}"
    )

    docker run --rm --network host \
        "${MOUNTS[@]}" \
        -e "PBS_REPOSITORY=${PBS_REPOSITORY_FULL}" \
        ${PBS_PASSWORD:+-e "PBS_PASSWORD=${PBS_PASSWORD}"} \
        ${PBS_PASSWORD_FILE:+-e "PBS_PASSWORD_FILE=${PBS_PASSWORD_FILE}"} \
        ${PBS_FINGERPRINT:+-e "PBS_FINGERPRINT=${PBS_FINGERPRINT}"} \
        "$PBS_DOCKER_IMAGE" \
        "${pbs_args[@]}"
}

pbs::run_backup() {
    case "$PBS_CLIENT_MODE" in
        apt)    pbs::run_apt ;;
        docker) pbs::run_docker ;;
        *) logs::error "PBS_CLIENT_MODE invalide: $PBS_CLIENT_MODE (apt|docker)"; exit 1 ;;
    esac
}


pbs::check_connection() {
    logs::info "Mode test de connexion à PBS activé."

    local datastore="${PBS_DATASTORE_ARG:-${PBS_DATASTORE_DEFAULT:-backup}}"
    local repo_full="${PBS_REPOSITORY}:${datastore}"
    local ns_arg=()
    [[ -n "${PBS_NAMESPACE_ARG:-${PBS_NAMESPACE:-}}" ]] && ns_arg=(--ns "${PBS_NAMESPACE_ARG:-${PBS_NAMESPACE:-}}")

    local check_success=0
    local check_output=""

    if [[ "$PBS_CLIENT_MODE" == "docker" ]]; then
        check_output=$(docker run --rm --network host \
            ${PBS_FINGERPRINT:+-e "PBS_FINGERPRINT=${PBS_FINGERPRINT}"} \
            ${PBS_PASSWORD:+-e "PBS_PASSWORD=${PBS_PASSWORD}"} \
            ${PBS_PASSWORD_FILE:+-e "PBS_PASSWORD_FILE=${PBS_PASSWORD_FILE}"} \
            "$PBS_DOCKER_IMAGE" list --repository "$repo_full" "${ns_arg[@]}" 2>&1) && check_success=1
    else
        check_output=$(env ${PBS_FINGERPRINT:+PBS_FINGERPRINT="$PBS_FINGERPRINT"} \
            ${PBS_PASSWORD:+PBS_PASSWORD="$PBS_PASSWORD"} \
            ${PBS_PASSWORD_FILE:+PBS_PASSWORD_FILE="$PBS_PASSWORD_FILE"} \
            proxmox-backup-client list --repository "$repo_full" "${ns_arg[@]}" 2>&1) && check_success=1
    fi

    echo -e "\n--- Résultat du test PBS ---"
    echo "$check_output"
    if [[ $check_success -eq 1 ]]; then
        logs::info "Connexion à PBS OK."
        return 0
    else
        logs::error "Échec de connexion à PBS."
        return 2
    fi
}
