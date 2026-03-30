#!/bin/bash
#
# Script de sauvegarde MariaDB (ElkarBackup) amélioré
# Fonctionnalités:
# - Envoi vers Proxmox Backup Server (PBS)
# - Publication de métriques vers Home Assistant via MQTT
# - Gestion d'erreurs robuste
# - Logging détaillé
# - Configuration centralisée
# - Sauvegarde locale limitée + distant PBS
#
# Usage:
#   ./backup_elkarbackup.sh [--backup|--check|--dummy-run|--help]
#   --backup    : Mode normal de sauvegarde
#   --check     : Vérifie uniquement la connexion PBS
#   --dummy-run : Mode test avec fichiers dummy
#   --help      : Affiche l'aide (par défaut si aucun argument)
#

set -euo pipefail

# Répertoire du script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup_elkarbackup.conf"

source "${SCRIPT_DIR}/libs/logs.sh"
source "${SCRIPT_DIR}/libs/config.sh"
source "${SCRIPT_DIR}/libs/cli.sh"
source "${SCRIPT_DIR}/libs/lock.sh"
source "${SCRIPT_DIR}/libs/tools.sh"
source "${SCRIPT_DIR}/modules/pbs.sh"
source "${SCRIPT_DIR}/modules/mqtt.sh"
source "${SCRIPT_DIR}/modules/dump.sh"

cli::parse "$@"

# Lock
lock::check "$MODE" "$SCRIPT_DIR"

# Config
config::load "$CONFIG_FILE" "$MODE" "$SCRIPT_DIR" "$REPO_ROOT"

# Logs
logs::init "$SCRIPT_DIR"

# MQTT topics: construits en dur dans le script (alignés sur CLI)
# Pas besoin de définir `MQTT_DEVICE_TOPIC`/`MQTT_STATE_TOPIC` dans la conf.
MQTT_DEVICE_TOPIC="homeassistant/device/backup/${PBS_BACKUP_ID}/config"
MQTT_STATE_TOPIC="backup/${PBS_BACKUP_ID}/state"


# Obtenir l'ID du conteneur Docker (sauf en mode check)
DOCKER_ID=""
# Vérifier l'existence du conteneur Docker uniquement en exécution réelle
if [[ "$MODE" == "backup" ]]; then
    # Si un nom est configuré, tenter de retrouver (acceptant les correspondances partielles)
    if [[ -n "${DOCKER_CONTAINER_NAME:-}" ]]; then
        DOCKER_ID=$(docker ps --no-trunc -aqf "name=${DOCKER_CONTAINER_NAME}" 2>/dev/null | head -n1 || true)
    fi

    if [[ -z "$DOCKER_ID" ]]; then
        echo "ERREUR: Conteneur Docker '${DOCKER_CONTAINER_NAME:-}' non trouvé"
        echo "Vérifiez DOCKER_CONTAINER_NAME dans $CONFIG_FILE ou lancez le conteneur MariaDB"
        rm -f "$LOCK_FILE"
        exit 1
    fi
fi

# ============================================================================
# FONCTIONS UTILITAIRES
# ============================================================================

# Cleanup trap
tools::install_trap "$MODE" "$LOCK_FILE"

main() {
    log::info "=== Début de la sauvegarde MariaDB ==="
    log::info "Bases de données à sauvegarder: $(IFS=,; echo "${DB_NAMES[*]}")"

    # Publication de la découverte MQTT au début
    mqtt::publish_discovery

    # Initialisation du statut
    BACKUP_STATUS="running"
    mqtt::publish_metrics

    # Création des répertoires de sauvegarde
    dump::create_backup_directory

    # Sauvegarde de chaque base de données
    local all_dumps_successful=true
    local backup_files_for_pbs=()

    for db_name in "${DB_NAMES[@]}"; do
        log::info "Traitement de la base de données: $db_name"
        
        if dump::perform_database_backup "$db_name"; then
            local backup_file="${BACKUP_DIR}${BACKUP_DATE}_${db_name}${FILE_SUFFIX}"
            
            # Ajouter directement le fichier à PBS sans compression locale
            backup_files_for_pbs+=("$backup_file")
            log::info "Dump de la base de données réussi pour '$db_name' (sera compressé par PBS)"
            dump::cleanup_old_backups "$db_name"
        else
            log::error "Échec du dump pour '$db_name'"
            all_dumps_successful=false
        fi
    done
    
    # Pas de compression locale, les fichiers seront compressés par PBS
    COMPRESSION_RATIO=0

    # Envoi vers PBS: d'abord les dumps SQL, puis (comportement historique) le répertoire source/backups
    local pbs_successful=true
    if [[ ${#backup_files_for_pbs[@]} -gt 0 ]]; then
        if ! pbs::backup_files "${backup_files_for_pbs[@]}"; then
            log::warn "Sauvegardes créées localement mais échec de l'envoi des fichiers SQL vers PBS"
            pbs_successful=false
        else
            log::info "Envoi PBS des fichiers SQL réussi"
        fi
    fi

    # Inclure le répertoire source et le répertoire de backups si configurés
    if [[ -n "${BACKUP_SOURCE_DIR:-}" ]]; then
        if pbs::backup_paths; then
            log::info "Envoi PBS du répertoire source/backups réussi"
        else
            log::warn "Échec de l'envoi du répertoire source/backups vers PBS"
            pbs_successful=false
        fi
    fi

    # Détermination du statut final
    if [[ "$all_dumps_successful" == true ]]; then
        if [[ "$pbs_successful" == true ]]; then
            BACKUP_STATUS="success"
            log::info "=== Sauvegarde terminée avec succès ==="
        else
            BACKUP_STATUS="pbs_failed"
            ERROR_MESSAGE="Sauvegardes locales réussies mais échec de l'envoi PBS"
            log::warn "Sauvegarde locale réussie mais problèmes d'envoi PBS"
        fi
    else
        BACKUP_STATUS="dump_failed"
        ERROR_MESSAGE="Échec partiel ou total du dump des bases de données"
        log::error "Problèmes de dump détectés"
    fi

    # Calcul de la durée finale
    BACKUP_DURATION=$(($(date +%s) - START_TIME))

    log::info "Durée totale: ${BACKUP_DURATION}s ($(displaytime $BACKUP_DURATION))"
    log::info "Taille finale compressée: ${TOTAL_COMPRESSED_SIZE}MB"
    log::info "Ratio de compression: ${COMPRESSION_RATIO}%"
    log::info "Fichiers sauvegardés: $(IFS=,; echo "${BACKUP_FILES[*]##*/}")"
}


# ============================================================================
# POINT D'ENTRÉE
# ============================================================================

# Mode check: vérifier seulement la connexion PBS
if [[ "$MODE" == "check" ]]; then
    # LOG_FILE déjà initialisé dans logs/ du script
    touch "$LOG_FILE"
    
    # Vérifier les dépendances minimales
    tools::check_dependencies
    
    # Tenter la connexion PBS
    pbs::check_connection
    exit $?
fi

# Pour les autres modes, continuer avec les vérifications normales
tools::check_dependencies

# Création du fichier de log si nécessaire
touch "$LOG_FILE"

# Exécution principale
main

log::info "=== Script terminé ==="

