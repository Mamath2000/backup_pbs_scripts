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

    if [[ ${#files[@]} -eq 0 ]]; then
        log::error "pbs::backup_files: aucun fichier fourni"
        return 1
    fi

    if [[ -z "${PBS_REPOSITORY:-}" ]]; then
        log::error "PBS_REPOSITORY non défini"
        return 1
    fi

    # Vérifier et construire l'image si nécessaire
    if ! pbs::ensure_image; then
        log::error "Impossible de préparer l'image Docker PBS"
        return 1
    fi

    local backup_dir="${BACKUP_DIR%/}"

    # Créer un répertoire de staging sous le répertoire de backup
    local staging_dir
    staging_dir=$(mktemp -d -p "${backup_dir}" ".pbs-staging.${BACKUP_DATE}.XXXXXX") || {
        log::error "Impossible de créer le répertoire de staging PBS"
        return 1
    }

    # Nettoyage local du staging en cas d'interruption
    trap 'rm -rf "$staging_dir" || true' INT TERM EXIT

    mkdir -p "$staging_dir/meta" "$staging_dir/data"

    # Metadata simple
    cat >"$staging_dir/meta/metadata.json" <<EOF
{
  "backup_date": "${BACKUP_DATE}",
  "backup_id": "${PBS_BACKUP_ID:-}"
}
EOF

    local f
    for f in "${files[@]}"; do
        if [[ -z "$f" ]]; then
            continue
        fi
        if [[ ! -f "$f" ]]; then
            log::warn "Fichier introuvable pour PBS: $f"
            continue
        fi
        local bname
        bname=$(basename "$f")
        if ! ln "$f" "$staging_dir/data/$bname" 2>/dev/null; then
            if ! cp -a "$f" "$staging_dir/data/$bname"; then
                log::error "Échec préparation du fichier pour PBS: $f"
                rm -rf "$staging_dir" || true
                trap - INT TERM EXIT
                return 1
            fi
        fi
    done

    # Appel au runner PBS qui s'attend à un répertoire staging contenant meta/ et data/
    if pbs::run_backup "$staging_dir"; then
        log::info "Envoi PBS réussi pour les fichiers fournis"
        rm -rf "$staging_dir" || true
        trap - INT TERM EXIT
        return 0
    else
        log::error "Échec de l'envoi PBS"
        rm -rf "$staging_dir" || true
        trap - INT TERM EXIT
        return 1
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
