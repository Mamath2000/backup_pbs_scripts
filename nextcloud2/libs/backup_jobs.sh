#!/usr/bin/env bash

nextcloud::jobs::copy_path_into_config_stage() {
    local original_path="$1"
    local source_path
    source_path="$(nextcloud::tools::resolve_path "$original_path")"

    if [[ ! -e "$source_path" ]]; then
        nextcloud::logs::error "Chemin de configuration introuvable: $source_path"
        return 1
    fi

    local relative_path="${source_path#/}"
    local destination_parent="${WORK_RUN_DIR}/config/files/$(dirname "$relative_path")"
    mkdir -p "$destination_parent"
    cp -a "$source_path" "$destination_parent/"
    nextcloud::logs::info "Ajout au staging config: $source_path"
}

nextcloud::jobs::copy_dump_into_config_stage() {
    if [[ -z "${CURRENT_DUMP_FILE:-}" || ! -f "$CURRENT_DUMP_FILE" ]]; then
        nextcloud::logs::error "Dump courant introuvable pour le staging config"
        return 1
    fi

    cp -a "$CURRENT_DUMP_FILE" "${WORK_RUN_DIR}/config/dump/"
    nextcloud::logs::info "Dump ajouté au staging config: $CURRENT_DUMP_FILE"
}

nextcloud::jobs::is_user_backup_path() {
    local candidate_path
    candidate_path="$(nextcloud::tools::resolve_path "$1")"

    local user_entry user_path
    for user_entry in "${USER_BACKUPS[@]}"; do
        [[ -z "$user_entry" ]] && continue
        nextcloud::jobs::parse_user_backup_entry "$user_entry"
        user_path="$(nextcloud::tools::resolve_path "$USER_ENTRY_PATH")"
        if [[ "$candidate_path" == "$user_path" ]]; then
            return 0
        fi
    done

    return 1
}

nextcloud::jobs::stage_data_root() {
    local data_root
    data_root="$(nextcloud::tools::resolve_path "$NEXTCLOUD_DATA_ROOT")"
    nextcloud::tools::require_directory "$data_root"

    local stage_root="${WORK_RUN_DIR}/config/data-root"
    local file_path dir_path dir_name pattern should_copy

    while IFS= read -r -d '' file_path; do
        cp -a "$file_path" "$stage_root/"
        nextcloud::logs::info "Fichier data-root ajouté: $(basename "$file_path")"
    done < <(find "$data_root" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)

    while IFS= read -r -d '' dir_path; do
        dir_name="$(basename "$dir_path")"

        if [[ "$dir_name" == appdata_* ]]; then
            nextcloud::logs::info "Répertoire data-root exclu du package config: $dir_name"
            continue
        fi

        should_copy=false

        for pattern in "${DATA_ROOT_INCLUDE_DIRS[@]}"; do
            if [[ "$dir_name" == $pattern ]]; then
                should_copy=true
                break
            fi
        done

        if [[ "$should_copy" != "true" ]]; then
            continue
        fi

        if nextcloud::jobs::is_user_backup_path "$dir_path"; then
            nextcloud::logs::info "Répertoire data-root ignoré car déjà sauvegardé comme user: $dir_name"
            continue
        fi

        cp -a "$dir_path" "$stage_root/"
        nextcloud::logs::info "Répertoire data-root ajouté: $dir_name"
    done < <(find "$data_root" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
}

nextcloud::jobs::run_appdata_backups() {
    local data_root
    data_root="$(nextcloud::tools::resolve_path "$NEXTCLOUD_DATA_ROOT")"
    nextcloud::tools::require_directory "$data_root"

    local dir_path dir_name safe_name backup_name

    while IFS= read -r -d '' dir_path; do
        dir_name="$(basename "$dir_path")"
        safe_name="$(nextcloud::tools::sanitize_component "$dir_name")"
        backup_name="config-${safe_name}"

        nextcloud::jobs::run_cli_backup "$backup_name" "$dir_path" "$CONFIG_DATASTORE"
    done < <(find "$data_root" -mindepth 1 -maxdepth 1 -type d -name 'appdata_*' -print0 | sort -z)
}

nextcloud::jobs::build_config_stage() {
    nextcloud::jobs::copy_dump_into_config_stage
    nextcloud::docker::export_config_php "${WORK_RUN_DIR}/config/nextcloud/config.php"
    nextcloud::jobs::stage_data_root

    local item
    for item in "${CONF_PATHS[@]}"; do
        [[ -z "$item" ]] && continue
        nextcloud::jobs::copy_path_into_config_stage "$item"
    done
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
    local -a failed_datastores=()
    local datastore user_entry found

    datastores_to_check+=("${CONFIG_DATASTORE:-}")
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
            nextcloud::logs::info "Test de connexion PBS pour le datastore: $datastore (namespace: ${PBS_NAMESPACE})"
            if ! "$CLI_BACKUP_SCRIPT" --check --datastore "$datastore" --namespace "$PBS_NAMESPACE"; then
                nextcloud::logs::error "Échec du test PBS pour le datastore: $datastore"
                failed_datastores+=("$datastore")
            fi
        else
            nextcloud::logs::info "Test de connexion PBS sur le datastore par défaut de la CLI (namespace: ${PBS_NAMESPACE})"
            if ! "$CLI_BACKUP_SCRIPT" --check --namespace "$PBS_NAMESPACE"; then
                nextcloud::logs::error "Échec du test PBS sur le datastore par défaut de la CLI"
                failed_datastores+=("<default>")
            fi
        fi
    done

    if [[ ${#failed_datastores[@]} -gt 0 ]]; then
        nextcloud::logs::error "Datastores PBS en échec: ${failed_datastores[*]}"
        return 1
    fi
}