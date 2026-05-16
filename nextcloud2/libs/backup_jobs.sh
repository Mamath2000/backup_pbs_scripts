#!/usr/bin/env bash

nextcloud::jobs::copy_path_into_conf_stage() {
    local original_path="$1"
    local source_path
    source_path="$(nextcloud::tools::resolve_path "$original_path")"

    if [[ ! -e "$source_path" ]]; then
        nextcloud::logs::error "Chemin de configuration introuvable: $source_path"
        return 1
    fi

    local relative_path="${source_path#/}"
    local destination_parent="${WORK_RUN_DIR}/conf/files/$(dirname "$relative_path")"
    mkdir -p "$destination_parent"
    cp -a "$source_path" "$destination_parent/"
    nextcloud::logs::info "Ajout au bundle de configuration: $source_path"
}

nextcloud::jobs::build_conf_bundle() {
    nextcloud::docker::export_config_php

    local item
    for item in "${CONF_PATHS[@]}"; do
        [[ -z "$item" ]] && continue
        nextcloud::jobs::copy_path_into_conf_stage "$item"
    done

    cat > "${WORK_RUN_DIR}/conf/generated/manifest.txt" <<EOF
run_timestamp=${RUN_TIMESTAMP}
db_name=${DB_NAME}
config_file=${NEXTCLOUD_CONFIG_PATH}
conf_paths=$(IFS=';'; echo "${CONF_PATHS[*]}")
shared_data_roots=$(IFS=';'; echo "${CONF_SHARED_DATA_ROOTS[*]}")
user_backups=$(IFS=';'; echo "${USER_BACKUPS[*]}")
dump_datastore=${DUMP_DATASTORE}
conf_datastore=${CONF_DATASTORE}
shared_data_datastore=${SHARED_DATA_DATASTORE}
EOF
}

nextcloud::jobs::run_cli_backup() {
    local backup_name="$1"
    local backup_dir="$2"
    local datastore="${3:-}"
    shift 3

    local -a cmd=("$CLI_BACKUP_SCRIPT" "$backup_name" -d "$backup_dir")
    if [[ -n "$datastore" ]]; then
        cmd+=(--datastore "$datastore")
    fi
    if [[ -n "${PBS_NAMESPACE:-}" ]]; then
        cmd+=(--namespace "$PBS_NAMESPACE")
    fi

    local exclude
    for exclude in "$@"; do
        cmd+=(-e "$exclude")
    done

    if [[ -n "$datastore" && -n "${PBS_NAMESPACE:-}" ]]; then
        nextcloud::logs::info "Lancement CLI PBS: ${backup_name} -> ${backup_dir} (datastore: ${datastore}, namespace: ${PBS_NAMESPACE})"
    elif [[ -n "$datastore" ]]; then
        nextcloud::logs::info "Lancement CLI PBS: ${backup_name} -> ${backup_dir} (datastore: ${datastore})"
    elif [[ -n "${PBS_NAMESPACE:-}" ]]; then
        nextcloud::logs::info "Lancement CLI PBS: ${backup_name} -> ${backup_dir} (namespace: ${PBS_NAMESPACE})"
    else
        nextcloud::logs::info "Lancement CLI PBS: ${backup_name} -> ${backup_dir}"
    fi

    "${cmd[@]}"
}

nextcloud::jobs::parse_user_backup_entry() {
    local entry="$1"

    IFS='|' read -r USER_ENTRY_PATH USER_ENTRY_DATASTORE <<< "$entry"
    USER_ENTRY_PATH="${USER_ENTRY_PATH%,}"
    USER_ENTRY_DATASTORE="${USER_ENTRY_DATASTORE%,}"

    if [[ -z "$USER_ENTRY_PATH" || -z "$USER_ENTRY_DATASTORE" ]]; then
        nextcloud::logs::error "Entrée USER_BACKUPS invalide: '$entry' (format attendu: /chemin/utilisateur|datastore)"
        return 1
    fi
}

nextcloud::jobs::run_shared_data_backups() {
    local root_index=0
    local shared_root shared_root_path shared_name

    for shared_root in "${CONF_SHARED_DATA_ROOTS[@]}"; do
        [[ -z "$shared_root" ]] && continue
        shared_root_path="$(nextcloud::tools::resolve_path "$shared_root")"
        nextcloud::tools::require_directory "$shared_root_path"

        local -a excludes=()
        local user_entry user_dir_path user_parent_path user_dir_name

        for user_entry in "${USER_BACKUPS[@]}"; do
            [[ -z "$user_entry" ]] && continue
            nextcloud::jobs::parse_user_backup_entry "$user_entry"
            user_dir_path="$(nextcloud::tools::resolve_path "$USER_ENTRY_PATH")"
            user_parent_path="$(dirname "$user_dir_path")"

            if [[ "$user_parent_path" != "$shared_root_path" ]]; then
                continue
            fi

            user_dir_name="$(basename "$user_dir_path")"
            excludes+=("/${user_dir_name}")
        done

        local root_file_count
        root_file_count="$(find "$shared_root_path" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')"
        local root_dir_count
        root_dir_count="$(find "$shared_root_path" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')"
        if [[ "$root_dir_count" == "0" && "$root_file_count" == "0" ]]; then
            nextcloud::logs::warn "Aucun contenu partagé à sauvegarder dans $shared_root_path"
            root_index=$((root_index + 1))
            continue
        fi

        shared_name="${CONF_BACKUP_NAME}-shared-data"
        if [[ ${#CONF_SHARED_DATA_ROOTS[@]} -gt 1 ]]; then
            shared_name+="-$((root_index + 1))"
        fi

        nextcloud::jobs::run_cli_backup "$shared_name" "$shared_root_path" "$SHARED_DATA_DATASTORE" "${excludes[@]}"
        root_index=$((root_index + 1))
    done
}

nextcloud::jobs::run_user_backups() {
    local user_entry user_dir_path user_name safe_user backup_name datastore

    for user_entry in "${USER_BACKUPS[@]}"; do
        [[ -z "$user_entry" ]] && continue
        nextcloud::jobs::parse_user_backup_entry "$user_entry"

        user_dir_path="$(nextcloud::tools::resolve_path "$USER_ENTRY_PATH")"
        datastore="$USER_ENTRY_DATASTORE"
        nextcloud::tools::require_directory "$user_dir_path"

        user_name="$(basename "$user_dir_path")"
        safe_user="$(nextcloud::tools::sanitize_component "$user_name")"
        backup_name="${USER_BACKUP_NAME_PREFIX}-${safe_user}"

        nextcloud::jobs::run_cli_backup "$backup_name" "$user_dir_path" "$datastore"
    done
}

nextcloud::jobs::cli_check() {
    nextcloud::logs::info "Vérification du moteur CLI PBS"

    local -a datastores_to_check=()
    local datastore user_entry found

    datastores_to_check+=("")
    for user_entry in "${USER_BACKUPS[@]}"; do
        [[ -z "$user_entry" ]] && continue
        nextcloud::jobs::parse_user_backup_entry "$user_entry"

        found=false
        for datastore in "${datastores_to_check[@]}"; do
            if [[ "$datastore" == "$USER_ENTRY_DATASTORE" ]]; then
                found=true
                break
            fi
        done

        if [[ "$found" == "false" ]]; then
            datastores_to_check+=("$USER_ENTRY_DATASTORE")
        fi
    done

    for datastore in "${datastores_to_check[@]}"; do
        if [[ -n "$datastore" ]]; then
            "$CLI_BACKUP_SCRIPT" --check --datastore "$datastore" --namespace "$PBS_NAMESPACE"
        else
            "$CLI_BACKUP_SCRIPT" --check --namespace "$PBS_NAMESPACE"
        fi
    done
}