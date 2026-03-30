#!/usr/bin/env bash

pbs::check_connection() {
    log::info "=== Vérification de la connexion PBS ==="
    
    # PBS envoi : le script considère l'envoi vers PBS comme actif par défaut

    if [[ -z "${PBS_REPOSITORY:-}" ]]; then
        log::error "PBS_REPOSITORY non défini"
        return 1
    fi

    if [[ -z "${PBS_PASSWORD:-}" ]]; then
        log::error "PBS_PASSWORD non défini"
        return 1
    fi

    # Vérifier et construire l'image si nécessaire
    if ! pbs::ensure_image; then
        log::error "Impossible de préparer l'image Docker PBS"
        return 1
    fi

    # Utiliser l'image du client PBS (construite depuis pbs_client/) par défaut
    local image="${PBS_DOCKER_IMAGE:-proxmox-pbs-client:latest}"
    
    log::info "Repository: ${PBS_REPOSITORY_FULL}"
    log::info "Image Docker: ${image}"
    [[ -n "${PBS_FINGERPRINT:-}" ]] && log::info "Fingerprint: ${PBS_FINGERPRINT}"
    [[ -n "${PBS_NAMESPACE:-}" ]] && log::info "Namespace: ${PBS_NAMESPACE}"
    
    log::info "Test de connexion au serveur PBS..."
    
    # Test avec proxmox-backup-client login (appel explicite du binaire dans le conteneur)
    local test_result=0
    if docker run --rm --network host \
        -e "PBS_REPOSITORY=${PBS_REPOSITORY_FULL}" \
        ${PBS_PASSWORD:+-e "PBS_PASSWORD=${PBS_PASSWORD}"} \
        ${PBS_PASSWORD_FILE:+-e "PBS_PASSWORD_FILE=${PBS_PASSWORD_FILE}"} \
        ${PBS_FINGERPRINT:+-e "PBS_FINGERPRINT=${PBS_FINGERPRINT}"} \
        "$image" \
        list --repository "$PBS_REPOSITORY_FULL" ${PBS_NAMESPACE:+--ns "$PBS_NAMESPACE"}; then
        log::info "Connexion PBS réussie!"
        test_result=0
    else
        log::error "Échec de la connexion PBS"
        test_result=1
    fi
    
    return $test_result
}

pbs::run_backup() {
    local staging_dir="$1"
    local archive_name="${PBS_ARCHIVE_NAME:-elkarbackup.pxar}"
    local backup_id="${PBS_BACKUP_ID:-elkarbackup}"
    local backup_type="${PBS_BACKUP_TYPE:-host}"
    local pbs_namespace="${PBS_NAMESPACE:-}"
    local image="${PBS_DOCKER_IMAGE:-proxmox-pbs-client:latest}"

    # Vérifier et construire l'image si nécessaire
    if ! pbs::ensure_image; then
        log::error "Impossible de préparer l'image Docker PBS"
        return 1
    fi

    # En mode dummy-run, utiliser un backup_id différent
    if [[ "$MODE" == "dummy-run" ]]; then
        backup_id="${backup_id}-dummy"
        log::info "Mode DUMMY-RUN: Utilisation du backup_id: ${backup_id}"
    fi

    if [[ -z "${PBS_REPOSITORY:-}" ]]; then
        log::error "PBS_REPOSITORY non défini"
        return 1
    fi

    log::info "Envoi vers PBS: repository='${PBS_REPOSITORY_FULL}', backup_id='${backup_id}', type='${backup_type}'"

    local -a pbs_args=(
        backup
        "${archive_name}:/data"
        --backup-id "$backup_id"
        --backup-type "$backup_type"
        ${pbs_namespace:+--ns "$pbs_namespace"}
        --repository "$PBS_REPOSITORY_FULL"
    )

    docker run --rm --network host \
        -v "${staging_dir}:/data:ro" \
        -e "PBS_REPOSITORY=${PBS_REPOSITORY_FULL}" \
        ${PBS_PASSWORD:+-e "PBS_PASSWORD=${PBS_PASSWORD}"} \
        ${PBS_PASSWORD_FILE:+-e "PBS_PASSWORD_FILE=${PBS_PASSWORD_FILE}"} \
        ${PBS_FINGERPRINT:+-e "PBS_FINGERPRINT=${PBS_FINGERPRINT}"} \
        "$image" \
        "${pbs_args[@]}"
}

pbs::backup_files() {
    local -a files=("$@")

    local source_dir="${BACKUP_SOURCE_DIR}"
    local backup_dir="${BACKUP_DIR%/}"
    local source_name="${source_dir##*/}"
    local backup_name="${backup_dir##*/}"

    local source_safe
    local backup_safe
    source_safe=$(tools::sanitize_name "$source_name")
    backup_safe=$(tools::sanitize_name "$backup_name")

    local image="${PBS_DOCKER_IMAGE:-proxmox-pbs-client:latest}"

    # Construire les mounts et specs
    local -a mounts=()
    local -a specs=()
    if [[ "$PBS_CLIENT_MODE" == "docker" ]]; then
        mounts+=("--volume" "${source_dir}:/source:ro")
        specs+=("${source_safe}.pxar:/source")
        mounts+=("--volume" "${backup_dir}:/backups:ro")
        specs+=("${backup_safe}.pxar:/backups")
    else
        specs+=("${source_safe}.pxar:${source_dir}")
        specs+=("${backup_safe}.pxar:${backup_dir}")
    fi

    # Arguments additionnels: exclure les répertoires indésirables
    local -a extra_args_local=()
    extra_args_local+=(--exclude "backup" --exclude "mariadb/db")
    if [[ -n "${PBS_CHANGE_DETECTION_MODE:-}" ]]; then
        extra_args_local+=(--change-detection-mode "$PBS_CHANGE_DETECTION_MODE")
    fi
    if [[ -n "${PBS_CLIENT_EXTRA_ARGS:-}" ]]; then
        read -r -a extra_user_args <<< "$PBS_CLIENT_EXTRA_ARGS"
        extra_args_local+=("${extra_user_args[@]}")
    fi

    log::info "Envoi PBS direct: repository='${PBS_REPOSITORY_FULL}', source='${source_dir}', backups='${backup_dir}'"

    if [[ "$PBS_CLIENT_MODE" == "docker" ]]; then
        local -a pbs_args=(
            backup
            "${specs[@]}"
            --backup-id "${PBS_BACKUP_ID:-elkarbackup}"
            --backup-type "${PBS_BACKUP_TYPE:-host}"
            ${PBS_NAMESPACE:+--ns "$PBS_NAMESPACE"}
            --repository "${PBS_REPOSITORY_FULL}"
            "${extra_args_local[@]}"
        )

        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo "DRY-RUN: docker run --rm --network host ${mounts[*]} -e PBS_REPOSITORY=${PBS_REPOSITORY_FULL} $image ${pbs_args[*]}"
            return 0
        fi

        docker run --rm --network host \
            "${mounts[@]}" \
            -e "PBS_REPOSITORY=${PBS_REPOSITORY_FULL}" \
            ${PBS_PASSWORD:+-e "PBS_PASSWORD=${PBS_PASSWORD}"} \
            ${PBS_PASSWORD_FILE:+-e "PBS_PASSWORD_FILE=${PBS_PASSWORD_FILE}"} \
            ${PBS_FINGERPRINT:+-e "PBS_FINGERPRINT=${PBS_FINGERPRINT}"} \
            "$image" \
            "${pbs_args[@]}"

        return $?
    else
        # apt mode
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo "DRY-RUN: proxmox-backup-client backup ${specs[*]} --repository ${PBS_REPOSITORY_FULL} --backup-id ${PBS_BACKUP_ID:-elkarbackup} --backup-type ${PBS_BACKUP_TYPE:-host} ${extra_args_local[*]}"
            return 0
        fi

        env ${PBS_FINGERPRINT:+PBS_FINGERPRINT="$PBS_FINGERPRINT"} \
            ${PBS_PASSWORD:+PBS_PASSWORD="$PBS_PASSWORD"} \
            proxmox-backup-client backup "${specs[@]}" --repository "$PBS_REPOSITORY_FULL" --backup-id "${PBS_BACKUP_ID:-elkarbackup}" --backup-type "${PBS_BACKUP_TYPE:-host}" ${PBS_NAMESPACE:+--ns "$PBS_NAMESPACE"} "${extra_args_local[@]}"

        return $?
    fi
}

pbs::ensure_image() {
    local pbs_docker_image="${PBS_DOCKER_IMAGE:-proxmox-pbs-client:latest}"

    if docker image inspect "$pbs_docker_image" >/dev/null 2>&1; then
        log::debug "Image PBS déjà présente: $pbs_docker_image"
        return 0
    fi

    log::info "Image PBS non trouvée, construction via $REPO_ROOT/pbs_client/build_pbs_client.sh"

    if "$REPO_ROOT/pbs_client/build_pbs_client.sh"; then
        log::info "Image '$pbs_docker_image' construite avec succès"
        return 0
    else
        log::error "Échec de la construction de l'image '$pbs_docker_image' via $REPO_ROOT/pbs_client/build_pbs_client.sh"
        return 1
    fi
}
