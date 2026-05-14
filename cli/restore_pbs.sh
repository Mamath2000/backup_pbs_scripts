#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/libs/logs.sh"
source "${SCRIPT_DIR}/libs/config.sh"
source "${SCRIPT_DIR}/libs/tools.sh"
source "${SCRIPT_DIR}/libs/pbs_client.sh"

restore::usage() {
    cat <<EOF
Usage:
  $(basename "$0") "nom-backup" -t /repertoire/cible [--snapshot SNAPSHOT] [--archive ARCHIVE] [--datastore NAME] [--namespace NAME]
    $(basename "$0") "nom-backup" [--snapshot SNAPSHOT] [--archive ARCHIVE] --list-subdirs [--datastore NAME] [--namespace NAME]

Exemples:
  $(basename "$0") host-prod -t /srv/restore
  $(basename "$0") host-prod -t /srv/restore --snapshot host/host-prod/2026-05-14T08:00:00Z
    $(basename "$0") host-prod -t /srv/restore --subdir etc
    $(basename "$0") host-prod --snapshot host/host-prod/2026-05-14T08:00:00Z --archive root.pxar --list-subdirs
EOF
}

restore::parse() {
    BACKUP_NAME=""
    RESTORE_TARGET=""
    SELECTED_SNAPSHOT=""
    SELECTED_ARCHIVE=""
    RESTORE_SUBDIR=""
    LIST_SUBDIRS=false
    PBS_DATASTORE_ARG=""
    PBS_NAMESPACE_ARG=""

    if [[ $# -eq 0 ]]; then
        restore::usage
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--target)
                shift
                RESTORE_TARGET="${1:-}"
                ;;
            --snapshot)
                shift
                SELECTED_SNAPSHOT="${1:-}"
                ;;
            --archive)
                shift
                SELECTED_ARCHIVE="${1:-}"
                ;;
            --subdir)
                shift
                RESTORE_SUBDIR="${1:-}"
                ;;
            --list-subdirs)
                LIST_SUBDIRS=true
                ;;
            --datastore)
                shift
                PBS_DATASTORE_ARG="${1:-}"
                ;;
            --namespace|--ns)
                shift
                PBS_NAMESPACE_ARG="${1:-}"
                ;;
            -h|--help)
                restore::usage
                exit 0
                ;;
            -* )
                logs::error "Argument inconnu : $1"
                restore::usage
                exit 1
                ;;
            *)
                if [[ -z "$BACKUP_NAME" ]]; then
                    BACKUP_NAME="$1"
                else
                    logs::error "Argument en trop : $1"
                    restore::usage
                    exit 1
                fi
                ;;
        esac
        shift
    done

    if [[ -z "$BACKUP_NAME" ]]; then
        logs::error "Le nom du backup est obligatoire."
        restore::usage
        exit 1
    fi

    if [[ "$LIST_SUBDIRS" != "true" && -z "$RESTORE_TARGET" ]]; then
        logs::error "Le répertoire cible est obligatoire (-t|--target)."
        restore::usage
        exit 1
    fi

    if [[ "$LIST_SUBDIRS" != "true" && -e "$RESTORE_TARGET" ]]; then
        logs::error "Le répertoire cible existe déjà, restauration refusée: $RESTORE_TARGET"
        exit 1
    fi

    if [[ -n "$RESTORE_SUBDIR" ]]; then
        RESTORE_SUBDIR="${RESTORE_SUBDIR#./}"
        RESTORE_SUBDIR="${RESTORE_SUBDIR#/}"
        RESTORE_SUBDIR="${RESTORE_SUBDIR%/}"

        if [[ -z "$RESTORE_SUBDIR" ]]; then
            logs::error "Le sous-répertoire demandé est invalide."
            exit 1
        fi
    fi
}

restore::build_repo_args() {
    RESTORE_REPO_ARGS=(--repository "$PBS_REPOSITORY_FULL")

    local effective_ns="${PBS_NAMESPACE_ARG:-${PBS_NAMESPACE:-}}"
    if [[ -n "$effective_ns" ]]; then
        RESTORE_REPO_ARGS+=(--ns "$effective_ns")
    fi
}

restore::group_path() {
    printf '%s/%s' "${PBS_BACKUP_TYPE:-host}" "$BACKUP_NAME"
}

restore::normalize_archive_name() {
    local archive="$1"

    case "$archive" in
        *.pxar.didx|*.mpxar.didx|*.ppxar.didx)
            printf '%s\n' "${archive%.didx}"
            ;;
        *.img.fidx)
            printf '%s\n' "${archive%.fidx}"
            ;;
        *.pxar|*.mpxar|*.ppxar|*.img)
            printf '%s\n' "$archive"
            ;;
        *)
            printf '%s\n' ""
            ;;
    esac
}

restore::archive_exists() {
    local needle="$1"
    local item

    for item in "${ARCHIVES[@]:-}"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done

    return 1
}

restore::list_snapshots() {
    local group
    group="$(restore::group_path)"
    local output

    if ! output=$(PROXMOX_OUTPUT_NO_BORDER=1 PROXMOX_OUTPUT_NO_HEADER=1 \
        pbs::run_command snapshot list "$group" "${RESTORE_REPO_ARGS[@]}" --output-format text); then
        logs::error "Impossible de lister les snapshots pour $group"
        exit 1
    fi

    mapfile -t SNAPSHOT_LINES <<< "$output"

    local -a filtered_lines=()
    local -a filtered_snapshots=()
    local line snapshot

    for line in "${SNAPSHOT_LINES[@]:-}"; do
        [[ -z "$line" ]] && continue
        snapshot="${line%% *}"
        [[ -z "$snapshot" ]] && continue
        filtered_lines+=("$line")
        filtered_snapshots+=("$snapshot")
    done

    SNAPSHOT_LINES=("${filtered_lines[@]}")
    SNAPSHOTS=("${filtered_snapshots[@]}")

    if [[ ${#SNAPSHOTS[@]} -eq 0 ]]; then
        logs::error "Aucun snapshot trouvé pour $(restore::group_path)"
        exit 1
    fi
}

restore::choose_snapshot() {
    restore::list_snapshots

    if [[ -n "$SELECTED_SNAPSHOT" ]]; then
        local snapshot
        for snapshot in "${SNAPSHOTS[@]}"; do
            if [[ "$snapshot" == "$SELECTED_SNAPSHOT" ]]; then
                return 0
            fi
        done

        logs::error "Snapshot demandé introuvable : $SELECTED_SNAPSHOT"
        exit 1
    fi

    echo
    echo "Snapshots disponibles pour $(restore::group_path) :"
    local index
    local default_index=0
    local latest_snapshot="${SNAPSHOTS[0]}"
    for index in "${!SNAPSHOT_LINES[@]}"; do
        printf ' [%d] %s\n' "$((index + 1))" "${SNAPSHOT_LINES[$index]}"
        if [[ "${SNAPSHOTS[$index]}" > "$latest_snapshot" ]]; then
            latest_snapshot="${SNAPSHOTS[$index]}"
            default_index="$index"
        fi
    done

    while true; do
        local choice
        read -r -p "Sélectionner un snapshot [1-${#SNAPSHOTS[@]}] (Entrée = plus récent: $((default_index + 1))) : " choice

        if [[ -z "$choice" ]]; then
            SELECTED_SNAPSHOT="$latest_snapshot"
            return 0
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SNAPSHOTS[@]} )); then
            SELECTED_SNAPSHOT="${SNAPSHOTS[$((choice - 1))]}"
            return 0
        fi

        logs::warn "Sélection invalide."
    done
}

restore::list_archives() {
    local output

    if ! output=$(PROXMOX_OUTPUT_NO_BORDER=1 PROXMOX_OUTPUT_NO_HEADER=1 \
        pbs::run_command snapshot files "$SELECTED_SNAPSHOT" "${RESTORE_REPO_ARGS[@]}" --output-format text); then
        logs::error "Impossible de lister les archives du snapshot $SELECTED_SNAPSHOT"
        exit 1
    fi

    mapfile -t ARCHIVE_LINES <<< "$output"

    local -a restoreable_lines=()
    local -a restoreable_archives=()
    local line archive normalized display_suffix

    for line in "${ARCHIVE_LINES[@]:-}"; do
        [[ -z "$line" ]] && continue
        archive="${line%% *}"
        [[ -z "$archive" ]] && continue

        normalized="$(restore::normalize_archive_name "$archive")"
        [[ -z "$normalized" ]] && continue

        if restore::archive_exists "$normalized"; then
            continue
        fi

        display_suffix="${line#"$archive"}"
        restoreable_lines+=("$normalized$display_suffix")
        restoreable_archives+=("$normalized")
    done

    ARCHIVE_LINES=("${restoreable_lines[@]}")
    ARCHIVES=("${restoreable_archives[@]}")

    if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
        logs::error "Aucune archive restaurable trouvée dans $SELECTED_SNAPSHOT"
        exit 1
    fi
}

restore::choose_archive() {
    restore::list_archives

    if [[ -n "$SELECTED_ARCHIVE" ]]; then
        local archive
        for archive in "${ARCHIVES[@]}"; do
            if [[ "$archive" == "$SELECTED_ARCHIVE" ]]; then
                return 0
            fi
        done

        logs::error "Archive demandée introuvable : $SELECTED_ARCHIVE"
        exit 1
    fi

    if [[ ${#ARCHIVES[@]} -eq 1 ]]; then
        SELECTED_ARCHIVE="${ARCHIVES[0]}"
        return 0
    fi

    echo
    echo "Archives restaurables dans $SELECTED_SNAPSHOT :"
    local index
    for index in "${!ARCHIVE_LINES[@]}"; do
        printf ' [%d] %s\n' "$((index + 1))" "${ARCHIVE_LINES[$index]}"
    done

    while true; do
        local choice
        read -r -p "Sélectionner une archive [1-${#ARCHIVES[@]}] : " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ARCHIVES[@]} )); then
            SELECTED_ARCHIVE="${ARCHIVES[$((choice - 1))]}"
            return 0
        fi

        logs::warn "Sélection invalide."
    done
}

restore::require_pxar_archive() {
    if [[ ! "$SELECTED_ARCHIVE" =~ \.(pxar|mpxar|ppxar)$ ]]; then
        logs::error "L'option demandée nécessite une archive de type fichier (.pxar/.mpxar/.ppxar): $SELECTED_ARCHIVE"
        exit 1
    fi
}

restore::strip_catalog_prefix() {
    local raw_path="$1"
    local candidate
    local -a prefixes=(
        "./${SELECTED_ARCHIVE}/"
        "./${SELECTED_ARCHIVE}.didx/"
    )

    for candidate in "${prefixes[@]}"; do
        if [[ "$raw_path" == "$candidate"* ]]; then
            printf '%s\n' "${raw_path#"$candidate"}"
            return 0
        fi
    done

    if [[ "$raw_path" == ./*/* ]]; then
        printf '%s\n' "${raw_path#./*/}"
        return 0
    fi

    printf '%s\n' ""
}

restore::read_catalog() {
    pbs::run_command catalog dump "$SELECTED_SNAPSHOT" "${RESTORE_REPO_ARGS[@]}"
}

restore::list_subdirs() {
    restore::require_pxar_archive

    local catalog_output
    if ! catalog_output="$(restore::read_catalog 2>&1)"; then
        logs::error "Impossible de lister le catalogue du snapshot $SELECTED_SNAPSHOT"
        exit 1
    fi

    local -a directories=()
    local line entry_type raw_path relative_path

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        entry_type="${line%% *}"
        if [[ "$entry_type" != "d" ]]; then
            continue
        fi

        if [[ "$line" != *\"*\"* ]]; then
            continue
        fi

        raw_path="${line#*\"}"
        raw_path="${raw_path%%\"*}"

        relative_path="$(restore::strip_catalog_prefix "$raw_path")"
        [[ -z "$relative_path" || "$relative_path" == "." ]] && continue

        directories+=("$relative_path")
    done <<< "$catalog_output"

    if [[ ${#directories[@]} -eq 0 ]]; then
        logs::warn "Aucun sous-répertoire trouvé dans $SELECTED_ARCHIVE"
        return 0
    fi

    printf 'Sous-répertoires disponibles dans %s :\n' "$SELECTED_ARCHIVE"
    printf '%s\n' "${directories[@]}" | sort -u
}

restore::subdir_pattern() {
    printf '/%s/' "$RESTORE_SUBDIR"
}

restore::format_bytes() {
    local bytes="$1"

    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$bytes"
        return 0
    fi

    printf '%s B\n' "$bytes"
}

restore::collect_progress_stats() {
    local file_count=0
    local total_size=0

    if [[ -d "$RESTORE_TARGET" ]]; then
        file_count="$(find "$RESTORE_TARGET" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
        total_size="$(du -sb "$RESTORE_TARGET" 2>/dev/null | awk 'NR==1 {print $1}')"
    fi

    [[ -z "$file_count" ]] && file_count=0
    [[ -z "$total_size" ]] && total_size=0

    printf '%s;%s\n' "$file_count" "$total_size"
}

restore::monitor_progress() {
    local restore_pid="$1"
    local last_stats=""
    local current_stats file_count total_size

    logs::info "Restauration en cours, progression toutes les 5s..."

    while kill -0 "$restore_pid" 2>/dev/null; do
        current_stats="$(restore::collect_progress_stats)"
        if [[ "$current_stats" != "$last_stats" ]]; then
            IFS=';' read -r file_count total_size <<< "$current_stats"
            logs::info "Progression: ${file_count} fichier(s), $(restore::format_bytes "$total_size") restauré(s)"
            last_stats="$current_stats"
        fi

        sleep 5
    done
}

restore::run() {
    mkdir -p "$RESTORE_TARGET"

    local -a restore_args=(
        restore
        "$SELECTED_SNAPSHOT"
        "$SELECTED_ARCHIVE"
        "$RESTORE_TARGET"
        --allow-existing-dirs true
        "${RESTORE_REPO_ARGS[@]}"
    )

    if [[ -n "$RESTORE_SUBDIR" ]]; then
        restore::require_pxar_archive
        restore_args+=(--pattern "$(restore::subdir_pattern)")
    fi

    logs::info "Snapshot retenu: $SELECTED_SNAPSHOT"
    logs::info "Archive retenue: $SELECTED_ARCHIVE"
    logs::info "Répertoire cible: $RESTORE_TARGET"
    if [[ -n "$RESTORE_SUBDIR" ]]; then
        logs::info "Sous-répertoire retenu: $RESTORE_SUBDIR"
    fi

    PBS_RUN_MOUNTS=()
    if [[ "$PBS_CLIENT_MODE" == "docker" ]]; then
        PBS_RUN_MOUNTS=(--volume "${RESTORE_TARGET}:${RESTORE_TARGET}")
    fi

    pbs::run_command "${restore_args[@]}" &
    local restore_pid=$!

    restore::monitor_progress "$restore_pid" &
    local progress_pid=$!

    local status=0
    if wait "$restore_pid"; then
        status=0
    else
        status=$?
    fi

    kill "$progress_pid" 2>/dev/null || true
    wait "$progress_pid" 2>/dev/null || true

    local final_stats final_files final_size
    final_stats="$(restore::collect_progress_stats)"
    IFS=';' read -r final_files final_size <<< "$final_stats"
    logs::info "Bilan restore: ${final_files} fichier(s), $(restore::format_bytes "$final_size") restauré(s)"

    PBS_RUN_MOUNTS=()

    return $status
}

main() {
    restore::parse "$@"

    LOG_PREFIX="restore"

    config::load
    logs::init
    pbs::build_repository_full
    restore::build_repo_args

    restore::choose_snapshot
    restore::choose_archive

    if [[ "$LIST_SUBDIRS" == "true" ]]; then
        restore::list_subdirs
        exit 0
    fi

    restore::run

    logs::info "Restauration terminée"
}

main "$@"