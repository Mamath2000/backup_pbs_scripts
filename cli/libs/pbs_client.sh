#!/usr/bin/env bash

declare -a PBS_RUN_MOUNTS=()

pbs::ensure_image() {
    if [[ "$PBS_CLIENT_MODE" != "docker" ]]; then
        return 0
    fi

    if docker image inspect "$PBS_DOCKER_IMAGE" >/dev/null 2>&1; then
        return 0
    fi

    local build_script="${SCRIPT_DIR}/../pbs_client/build_pbs_client.sh"

    if [[ ! -f "$build_script" ]]; then
        logs::error "Image PBS absente et script de build introuvable: $build_script"
        return 1
    fi

    logs::warn "Image PBS absente, construction via ${build_script}"
    bash "$build_script"
}

pbs::build_repository_full() {
    local datastore="${PBS_DATASTORE_ARG:-${PBS_DATASTORE_DEFAULT:-backup}}"

    if [[ -n "${PBS_DATASTORE_ARG:-}" ]]; then
        PBS_REPOSITORY_FULL="${PBS_REPOSITORY%%:*}:${datastore}"
    elif [[ "$PBS_REPOSITORY" == *:* ]]; then
        PBS_REPOSITORY_FULL="$PBS_REPOSITORY"
    else
        PBS_REPOSITORY_FULL="${PBS_REPOSITORY}:${datastore}"
    fi
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

pbs::run_command() {
    local -a cmd=("$@")
    local -a run_mounts=("${PBS_RUN_MOUNTS[@]}")

    if [[ "$PBS_CLIENT_MODE" == "docker" ]]; then
        pbs::ensure_image || return 1

        docker run --rm --network host \
            "${run_mounts[@]}" \
            -e "PBS_REPOSITORY=${PBS_REPOSITORY_FULL}" \
            ${PBS_PASSWORD:+-e "PBS_PASSWORD=${PBS_PASSWORD}"} \
            ${PBS_PASSWORD_FILE:+-e "PBS_PASSWORD_FILE=${PBS_PASSWORD_FILE}"} \
            ${PBS_FINGERPRINT:+-e "PBS_FINGERPRINT=${PBS_FINGERPRINT}"} \
            ${PROXMOX_OUTPUT_NO_BORDER:+-e "PROXMOX_OUTPUT_NO_BORDER=${PROXMOX_OUTPUT_NO_BORDER}"} \
            ${PROXMOX_OUTPUT_NO_HEADER:+-e "PROXMOX_OUTPUT_NO_HEADER=${PROXMOX_OUTPUT_NO_HEADER}"} \
            ${PROXMOX_OUTPUT_FORMAT:+-e "PROXMOX_OUTPUT_FORMAT=${PROXMOX_OUTPUT_FORMAT}"} \
            "$PBS_DOCKER_IMAGE" \
            "${cmd[@]}"
        return $?
    fi

    local -a env_vars=()
    [[ -n "${PBS_FINGERPRINT:-}" ]] && env_vars+=("PBS_FINGERPRINT=${PBS_FINGERPRINT}")
    [[ -n "${PBS_PASSWORD:-}" ]] && env_vars+=("PBS_PASSWORD=${PBS_PASSWORD}")
    [[ -n "${PBS_PASSWORD_FILE:-}" ]] && env_vars+=("PBS_PASSWORD_FILE=${PBS_PASSWORD_FILE}")
    [[ -n "${PROXMOX_OUTPUT_NO_BORDER:-}" ]] && env_vars+=("PROXMOX_OUTPUT_NO_BORDER=${PROXMOX_OUTPUT_NO_BORDER}")
    [[ -n "${PROXMOX_OUTPUT_NO_HEADER:-}" ]] && env_vars+=("PROXMOX_OUTPUT_NO_HEADER=${PROXMOX_OUTPUT_NO_HEADER}")
    [[ -n "${PROXMOX_OUTPUT_FORMAT:-}" ]] && env_vars+=("PROXMOX_OUTPUT_FORMAT=${PROXMOX_OUTPUT_FORMAT}")

    env "${env_vars[@]}" proxmox-backup-client "${cmd[@]}"
}

pbs::run_docker() {
    logs::info "Exécution proxmox-backup-client (docker)"

    pbs::ensure_image || exit 1

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

    PBS_REPOSITORY_FULL="$repo_full"
    check_output=$(pbs::run_command list --repository "$repo_full" "${ns_arg[@]}" 2>&1) && check_success=1

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
