
pbs::is_enabled() {
    [[ "${PBS_ENABLED:-false}" == "true" ]]
}

# Calcul du PBS_BACKUP_ID selon le mode et la base
# - perdb: ${hostname}_${dbname}
# - cluster: ${hostname}_full
# - si TEST_MODE=true, préfixe 'test_' ajouté
pbs::compute_backup_id() {
    local mode="$1"
    local dbname="${2:-}"
    local host
    host=$(hostname -s 2>/dev/null || hostname)
    host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')

    if [[ "$mode" == "perdb" && -n "$dbname" ]]; then
        local db
        db=$(printf '%s' "$dbname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
        PBS_BACKUP_ID="${host}_${db}"
    else
        PBS_BACKUP_ID="${host}_full"
    fi

    if [[ "${TEST_MODE:-false}" == "true" ]]; then
        PBS_BACKUP_ID="test_${PBS_BACKUP_ID}"
    fi
}

pbs::run_backup() {
    local backup_id="${PBS_BACKUP_ID:-postgres}"
    local backup_type="host"
    local pbs_namespace="${PBS_NAMESPACE:-}"
    local pbs_client="${PBS_CLIENT:-proxmox-backup-client}"
    local pbs_client_mode="${PBS_CLIENT_MODE:-apt}"
    local pbs_docker_image="${PBS_DOCKER_IMAGE:-proxmox-pbs-client:latest}"

    if [[ -z "${PBS_REPOSITORY:-}" ]]; then
        logs::error "PBS_REPOSITORY non défini"
        return 1
    fi

    local -a backup_specs=("$@")

    local repo_arg="${PBS_REPOSITORY}"
    if [[ -n "${PBS_DATASTORE:-}" && "$repo_arg" != *":"* ]]; then
        repo_arg="${repo_arg}:${PBS_DATASTORE}"
    fi

    logs::info "Envoi vers PBS: repository='${repo_arg}', backup_id='${backup_id}', type='${backup_type}', mode='${pbs_client_mode}'"

    local -a env_args=("PBS_REPOSITORY=${repo_arg}")
    [[ -n "${PBS_PASSWORD:-}" ]] && env_args+=("PBS_PASSWORD=${PBS_PASSWORD}")
    [[ -n "${PBS_FINGERPRINT:-}" ]] && env_args+=("PBS_FINGERPRINT=${PBS_FINGERPRINT}")

    if [[ "$pbs_client_mode" == "docker" ]]; then
        # Docker: on monte les dossiers à sauvegarder dans /sourceX
        local -a docker_mounts=()
        local -a docker_specs=()
        local idx=0
        for spec in "${backup_specs[@]}"; do
            local archive_name="${spec%%:*}"
            local path="${spec#*:}"
            local mount_target="/source${idx}"
            docker_mounts+=(--volume "${path}:${mount_target}:ro")
            docker_specs+=("${archive_name}:${mount_target}")
            ((idx++))
        done

        local -a pbs_args=(backup)
        for spec in "${docker_specs[@]}"; do
            pbs_args+=("$spec")
        done
        pbs_args+=(--backup-id "$backup_id" --backup-type "$backup_type")
        if [[ -n "$pbs_namespace" ]]; then
            pbs_args+=(--ns "$pbs_namespace")
        fi
        pbs_args+=(--repository "$repo_arg")

        logs::debug "DEBUG PBS docker image: $pbs_docker_image"
        logs::debug "DEBUG PBS docker mounts: ${docker_mounts[*]}"
        logs::debug "DEBUG PBS docker args: ${pbs_args[*]}"

        local docker_out
            if docker_out=$(docker run --rm --network host \
            "${docker_mounts[@]}" \
            -e "PBS_REPOSITORY=${repo_arg}" \
            ${PBS_PASSWORD:+-e "PBS_PASSWORD=${PBS_PASSWORD}"} \
            ${PBS_FINGERPRINT:+-e "PBS_FINGERPRINT=${PBS_FINGERPRINT}"} \
            "$pbs_docker_image" \
            "${pbs_args[@]}" 2>&1); then
            echo "$docker_out" >>"$LOG_FILE" 2>&1
            return 0
        else
            logs::error "PBS docker client failed: $docker_out"
            echo "$docker_out" >>"$LOG_FILE" 2>&1
            return 1
        fi
    else
        # Mode natif (apt)
        local -a pbs_args=("${pbs_client}" backup)
        for spec in "${backup_specs[@]}"; do
            pbs_args+=("$spec")
        done
        pbs_args+=(--backup-id "$backup_id" --backup-type "$backup_type")
        if [[ -n "$pbs_namespace" ]]; then
            pbs_args+=(--ns "$pbs_namespace")
        fi
        pbs_args+=(--repository "$repo_arg")

        logs::debug "DEBUG PBS env: ${env_args[*]}"
        logs::debug "DEBUG PBS cmd: ${pbs_args[*]}"

        local apt_out
        if apt_out=$(env "${env_args[@]}" "${pbs_args[@]}" 2>&1); then
            echo "$apt_out" >>"$LOG_FILE" 2>&1
            return 0
        else
            logs::error "PBS client failed: $apt_out"
            echo "$apt_out" >>"$LOG_FILE" 2>&1
            return 1
        fi
    fi
}

pbs::backup_file() {
    local file_path="$1"

    if ! pbs::is_enabled; then
        logs::info "PBS désactivé, transfert ignoré"
        return 0
    fi

    if [[ ! -f "$file_path" ]]; then
        logs::error "Fichier introuvable pour PBS: $file_path"
        return 1
    fi

    local staging_dir
    staging_dir=$(mktemp -d -p "${BACKUP_DIR%/}" ".pbs-staging.${BACKUP_DATE}.XXXXXX")

    cat >"$staging_dir/metadata.json" <<EOF
{
    "backup_date": "${BACKUP_DATE}",
    "database": "${METADATA_DB:-}",
    "database_host": "${DB_HOST}",
    "file": "${BACKUP_FILE}"
}

EOF

    local staged_file="$staging_dir/$BACKUP_FILE"
    if ! ln "$file_path" "$staged_file" 2>/dev/null; then
        logs::warn "Impossible de créer un lien dur, copie du fichier pour PBS"
        if ! cp -a "$file_path" "$staged_file"; then
            logs::error "Échec de préparation du fichier pour PBS"
            rm -rf "$staging_dir" || true
            return 1
        fi
    fi

    mkdir -p "$staging_dir/meta" "$staging_dir/data"
    mv "$staging_dir/metadata.json" "$staging_dir/meta/metadata.json"

    mv "$staged_file" "$staging_dir/data/" || {
        logs::error "Échec de déplacement du fichier vers staging/data"
        rm -rf "$staging_dir" || true
        return 1
    }
    # L'archive pxar porte le nom du PBS_BACKUP_ID
    local meta_spec="metadata.pxar:${staging_dir}/meta"
    local data_spec="${PBS_BACKUP_ID}.pxar:${staging_dir}/data"

    logs::info "Préparation PBS: meta_spec='${meta_spec}', data_spec='${data_spec}', backup_id='${PBS_BACKUP_ID}'"

    if pbs::run_backup "$meta_spec" "$data_spec"; then
        logs::info "Envoi PBS réussi pour ${BACKUP_FILE} (backup_id=${PBS_BACKUP_ID})"
        PBS_OK="true"
        PBS_STATUS="ok"
        rm -rf "$staging_dir" || true
        return 0
    else
        logs::error "Échec de l'envoi PBS"
        PBS_OK="false"
        PBS_STATUS="failed"
        
        rm -rf "$staging_dir" || true
        return 1
    fi
}
