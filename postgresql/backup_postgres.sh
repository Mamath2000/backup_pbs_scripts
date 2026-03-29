#!/bin/bash
#
# Script de sauvegarde PostgreSQL amélioré
# Fonctionnalités:
# - Sauvegarde distante via PBS<
# - Publication de métriques vers Home Assistant via MQTT
# - Gestion d'erreurs robuste
# - Logging détaillé
# - Configuration centralisée
#
set -euo pipefail

source libs/logs.sh
source libs/config.sh
source libs/cli.sh
source libs/lock.sh
source libs/tools.sh
source modules/mqtt_discovery.sh
source modules/pbs_backup.sh
source modules/db_backup.sh
source modules/runner.sh

# Variables globales
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/backup_postgres.conf}"
LOCK_FILE="${LOCK_FILE:-${SCRIPT_DIR}/.backup_postgres.lock}"

# Parsing CLI
MODE=$(cli::parse "$@")
[[ -z "$MODE" ]] && cli::usage && exit 1

# Gestion du verrou
lock::check "$MODE" "$LOCK_FILE"
# Nettoyage du verrou à la sortie (INT/TERM/EXIT) pour éviter des verrous persistants
trap 'lock::cleanup "$LOCK_FILE"; exit' INT TERM EXIT

# Chargement de la config
config::load "$CONFIG_FILE" "$MODE"

logs::init

# # Interdire l'utilisation de DB_PASSWORD dans la configuration :
# # n'autoriser QUE l'authentification via ~/.pgpass (PGPASSFILE).
# if [[ -n "${DB_PASSWORD:-}" ]]; then
#     echo "ERREUR: DB_PASSWORD est défini dans la configuration. Le script n'autorise PAS les mots de passe en clair. Utilisez ~/.pgpass (PGPASSFILE) pour l'authentification PostgreSQL." >&2
#     [[ "${MODE}" != "check" ]] && lock::cleanup "$LOCK_FILE" || true
#     exit 1
# fi
# # Authentification: on suppose l'utilisation de ~/.pgpass (le script n'expose pas de mot de passe)

# # Si mode dummy-run demandé via CLI, activer TEST_MODE
# if [[ "${MODE}" == "dummy-run" ]]; then
#     TEST_MODE="true"
# fi

# METADATA_DB: utilisé pour la publication de métriques et metadata PBS
METADATA_DB=""
# Variables globales
START_TIME=$(date +%s)
BACKUP_DATE=$(date +"%Y%m%d%H%M")

# NOTE: suppression de FILE_SUFFIX global. Les fichiers sont nommés
# avec la date + PBS_BACKUP_ID et extension '.tar' (ou '.tar.gz').
# Les variables BACKUP_FILE / BACKUP_PATH seront initialisées avant
# chaque dump (perdb/cluster) après calcul de PBS_BACKUP_ID.
TEST_FILE_SUFFIX=""
BACKUP_FILE=""
BACKUP_PATH=""
COMPRESSED_PATH=""
BACKUP_FILE_COMPRESSED=""
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

# Statistiques de la sauvegarde
BACKUP_STATUS="unknown"
BACKUP_DURATION=0
BACKUP_SIZE=0
COMPRESSION_RATIO=0
ERROR_MESSAGE=""
PBS_STATUS="unknown"
PBS_OK="false"


# TEST_FILE_SUFFIX retiré (géré via PBS_BACKUP_ID)
TEST_FILE_SUFFIX=""

# Activer/désactiver la compression (true|false)
COMPRESSION_ENABLED="${COMPRESSION_ENABLED:-true}"

# ============================================================================
# FONCTION PRINCIPALE
# ============================================================================

main() {
    logs::info "=== Début de la sauvegarde PostgreSQL ==="
    backup::create_directory

    local overall_success=true

    case "${BACKUP_MODE:-cluster}" in
        cluster)
            runner::run_generic "cluster" "" "backup::perform_cluster_dump" || overall_success=false
            ;;
        perdb)
            for db in "${TARGETS_ARRAY[@]}"; do
                runner::run_generic "perdb" "$db" "backup::perform_database_dump" || overall_success=false
            done
            ;;
        *)
            logs::error "Mode inconnu: $BACKUP_MODE"
            return 1
            ;;
    esac

    BACKUP_DURATION=$(( $(date +%s) - START_TIME ))

    if [[ "$overall_success" == true ]]; then
        logs::info "=== Sauvegarde terminée avec succès ==="
    else
        logs::error "=== Sauvegarde échouée ==="
        return 1
    fi
}

# main() {
#     logs::info "=== Début de la sauvegarde PostgreSQL ==="

#     backup::create_directory
#     local overall_success=true

#     # PBS_BACKUP_ID is calculé par pbs::compute_backup_id() et inclut le préfixe 'test_' si nécessaire

#     case "${BACKUP_MODE:-cluster}" in
#         cluster)
#             logs::info "--- Mode: cluster (pg_basebackup) ---"

#             # Indiquer que c'est un backup cluster pour les métadonnées/metrics
#             METADATA_DB="cluster"
#             # Calculer l'ID PBS et nommer le fichier: date + PBS_BACKUP_ID + .tar
#             pbs::compute_backup_id "cluster"
#             BACKUP_FILE="${BACKUP_DATE}_${PBS_BACKUP_ID}.tar"
#             BACKUP_PATH="${BACKUP_DIR}${BACKUP_FILE}"
#             COMPRESSED_PATH="${BACKUP_PATH}.gz"
#             BACKUP_FILE_COMPRESSED="${BACKUP_FILE}.gz"

#             # Initialiser Home Assistant pour ce backup
#             mqtt::publish_mqtt_discovery "${PBS_BACKUP_ID}" "cluster"

#             # Marquer comme en cours et publier l'état initial
#             BACKUP_STATUS="running"
#             PBS_STATUS=$([ "${PBS_ENABLED:-false}" = "true" ] && echo "pending" || echo "disabled")
#             PBS_OK="false"
#             mqtt::publish_metrics "${PBS_BACKUP_ID}"

#             # Mesurer la durée de ce backup
#             local backup_start_ts
#             backup_start_ts=$(date +%s)

#             if backup::perform_cluster_dump; then
#                 pbs_successful=true
#                 if pbs::is_enabled; then
#                     if ! pbs::backup_file "$BACKUP_PATH"; then
#                         pbs_successful=false
#                     fi
#                 fi

#                 if [[ "${PBS_ENABLED:-false}" == "true" ]]; then
#                     PBS_STATUS=$([[ "$pbs_successful" == true ]] && echo "ok" || echo "failed")
#                     PBS_OK=$([[ "$pbs_successful" == true ]] && echo "true" || echo "false")
#                 else
#                     PBS_STATUS="disabled"
#                     PBS_OK="false"
#                 fi

#                 if ! backup::compress; then
#                     BACKUP_STATUS="compression_failed"
#                     ERROR_MESSAGE="Échec de la compression locale"
#                     overall_success=false
#                 else
#                     backup::cleanup_old
#                     if [[ "$pbs_successful" == true ]]; then
#                         BACKUP_STATUS="success"
#                         logs::info "Sauvegarde cluster terminée avec succès"
#                     else
#                         BACKUP_STATUS="failed"
#                         ERROR_MESSAGE="Échec de l'envoi PBS"
#                         logs::error "Sauvegarde locale compressée OK mais envoi PBS en échec pour cluster"
#                         overall_success=false
#                     fi
#                 fi

#                 # Calculer la durée et publier les métriques finales pour ce backup
#                 BACKUP_DURATION=$(( $(date +%s) - backup_start_ts ))
#                 mqtt::publish_metrics "${PBS_BACKUP_ID}"
#             else
#                 BACKUP_STATUS="dump_failed"
#                 ERROR_MESSAGE="Échec de pg_basebackup"
#                 PBS_STATUS=$([ "${PBS_ENABLED:-false}" = "true" ] && echo "failed" || echo "disabled")
#                 PBS_OK="false"
#                 overall_success=false
#             fi
#             ;;

#         perdb)
#             logs::info "--- Mode: perdb (pg_dump) ---"
#             for target_db in "${TARGETS_ARRAY[@]}"; do
#                 logs::info "Traitement de la base: $target_db"
#                 DB_NAME="$target_db"
#                 METADATA_DB="$DB_NAME"
#                 # Calculer l'ID PBS pour cette base
#                 pbs::compute_backup_id "perdb" "$DB_NAME"
#                 BACKUP_FILE="${BACKUP_DATE}_${PBS_BACKUP_ID}.tar"
#                 BACKUP_PATH="${BACKUP_DIR}${BACKUP_FILE}"
#                 COMPRESSED_PATH="${BACKUP_PATH}.gz"
#                 BACKUP_FILE_COMPRESSED="${BACKUP_FILE}.gz"

#                 # Initialiser Home Assistant pour ce backup spécifique
#                 mqtt::publish_mqtt_discovery "${PBS_BACKUP_ID}" "${DB_NAME}"

#                 # Marquer comme en cours et publier l'état initial
#                 BACKUP_STATUS="running"
#                 PBS_STATUS=$([ "${PBS_ENABLED:-false}" = "true" ] && echo "pending" || echo "disabled")
#                 PBS_OK="false"
#                 mqtt::publish_metrics "${PBS_BACKUP_ID}"

#                 # Mesurer la durée de ce backup
#                 local backup_start_ts
#                 backup_start_ts=$(date +%s)

#                 if backup::perform_database_dump; then
#                     pbs_successful=true
#                     if pbs::is_enabled; then
#                         if ! pbs::backup_file "$BACKUP_PATH"; then
#                             pbs_successful=false
#                         fi
#                     fi

#                     if ! backup::compress; then
#                         logs::error "Échec de la compression pour $DB_NAME"
#                         overall_success=false
#                         BACKUP_STATUS="compression_failed"
#                         ERROR_MESSAGE="Échec compression pour $DB_NAME"
#                     else
#                         backup::cleanup_old
#                         if [[ "$pbs_successful" == true ]]; then
#                             logs::info "Sauvegarde de $DB_NAME terminée avec succès"
#                             BACKUP_STATUS="success"
#                         else
#                             logs::error "Sauvegarde locale OK mais envoi PBS en échec pour $DB_NAME"
#                             overall_success=false
#                             BACKUP_STATUS="failed"
#                             ERROR_MESSAGE="Échec envoi PBS pour $DB_NAME"
#                         fi
#                     fi
#                 else
#                     logs::error "Échec du dump pour $DB_NAME"
#                     overall_success=false
#                     BACKUP_STATUS="dump_failed"
#                     ERROR_MESSAGE="Échec dump pour $DB_NAME"
#                 fi

#                 # Mettre à jour l'état PBS global
#                 if [[ "${PBS_ENABLED:-false}" == "true" ]]; then
#                     PBS_STATUS=$([[ "$pbs_successful" == true ]] && echo "ok" || echo "failed")
#                     PBS_OK=$([[ "$pbs_successful" == true ]] && echo "true" || echo "false")
#                 else
#                     PBS_STATUS="disabled"
#                     PBS_OK="false"
#                 fi

#                 # Calculer la durée et publier les métriques finales pour cette base
#                 BACKUP_DURATION=$(( $(date +%s) - backup_start_ts ))
#                 mqtt::publish_metrics "${PBS_BACKUP_ID}"
#             done
#             if [[ "$overall_success" == true ]]; then
#                 BACKUP_STATUS="success"
#             fi
#             ;;

#         *)
#             logs::error "Mode de backup inconnu: ${BACKUP_MODE}. Attendu 'cluster' ou 'perdb'"
#             return 1
#             ;;
#     esac

#     BACKUP_DURATION=$(($(date +%s) - START_TIME))

#     if [[ "$overall_success" == true ]]; then
#         logs::info "=== Sauvegarde terminée avec succès ==="
#     else
#         logs::error "=== Sauvegarde échouée ==="
#         return 1
#     fi

#     logs::info "Durée totale: ${BACKUP_DURATION}s"
#     logs::info "Taille finale: ${BACKUP_SIZE}MB"
#     logs::info "Ratio de compression: ${COMPRESSION_RATIO}%"
# }

# ============================================================================
# POINT D'ENTRÉE
# ============================================================================

tools::check_dependencies
tools::check_config

    # touch "$LOG_FILE"

if [[ "${MODE}" == "check" ]]; then
    logs::info "MODE=check: exécution de test_pbs_connection.sh"
    "${SCRIPT_DIR}/test_pbs_connection.sh" "$CONFIG_FILE"
    exit $?
fi

if [[ "${MODE}" == "dummy-run" ]]; then
    logs::info "MODE=dummy-run: TEST_MODE activé"
    TEST_MODE="true"
fi

main

logs::info "=== Script terminé ==="
