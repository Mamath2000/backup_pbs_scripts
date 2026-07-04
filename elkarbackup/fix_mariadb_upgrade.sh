#!/usr/bin/env bash
#
# Corrige l'erreur:
# "Column count of mysql.proc is wrong ... Please use mariadb-upgrade"
#
# Actions:
# 1) Lit la configuration backup_elkarbackup.conf (si presente)
# 2) Lance mariadb-upgrade dans le conteneur MariaDB
# 3) Redemarre le conteneur
# 4) Verifie qu'un dump avec --routines --triggers fonctionne
#
# Usage:
#   ./fix_mariadb_upgrade.sh [--check-only] [--config /path/to/conf] [--container NAME] [--db NAME]
#
# Notes:
# - Utilise DB_USER/DB_PASSWORD/DOCKER_CONTAINER_NAME de la conf si disponibles.
# - Variables d'environnement possibles: MYSQL_ROOT_PASSWORD, DB_PASSWORD.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE_DEFAULT="${SCRIPT_DIR}/backup_elkarbackup.conf"

CHECK_ONLY=false
CONFIG_FILE="$CONFIG_FILE_DEFAULT"
CONTAINER_OVERRIDE=""
DB_OVERRIDE=""

log() {
  local level="$1"; shift
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

usage() {
  cat <<'EOF'
Usage:
  ./fix_mariadb_upgrade.sh [options]

Options:
  --check-only         Affiche le diagnostic sans corriger
  --config PATH        Chemin du fichier de configuration
  --container NAME     Nom du conteneur MariaDB (prioritaire)
  --db NAME            Base a tester pour le dump final
  -h, --help           Affiche cette aide
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      CHECK_ONLY=true
      shift
      ;;
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --container)
      CONTAINER_OVERRIDE="$2"
      shift 2
      ;;
    --db)
      DB_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log ERROR "Option inconnue: $1"
      usage
      exit 1
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  log ERROR "docker n'est pas installe ou non disponible"
  exit 1
fi

# Charger la configuration si disponible
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  log INFO "Configuration chargee: $CONFIG_FILE"
else
  log WARN "Configuration non trouvee: $CONFIG_FILE (continuation avec defaults/env)"
fi

CONTAINER_NAME="${CONTAINER_OVERRIDE:-${DOCKER_CONTAINER_NAME:-elkarbackup-db}}"
DB_USER_EFFECTIVE="${DB_USER:-root}"
DB_PASSWORD_EFFECTIVE="${DB_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"

# Selection d'une base de test
if [[ -n "$DB_OVERRIDE" ]]; then
  TEST_DB="$DB_OVERRIDE"
elif [[ -n "${DB_NAMES+x}" && ${#DB_NAMES[@]} -gt 0 ]]; then
  TEST_DB="${DB_NAMES[0]}"
else
  TEST_DB="elkarbackup"
fi

log INFO "Conteneur cible: $CONTAINER_NAME"
log INFO "Utilisateur DB: $DB_USER_EFFECTIVE"
log INFO "Base test dump: $TEST_DB"

if ! docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  log ERROR "Conteneur introuvable: $CONTAINER_NAME"
  exit 1
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]]; then
  log ERROR "Le conteneur existe mais n'est pas en cours d'execution: $CONTAINER_NAME"
  exit 1
fi

if [[ -z "$DB_PASSWORD_EFFECTIVE" ]]; then
  log ERROR "Mot de passe DB introuvable. Definis DB_PASSWORD dans la conf ou MYSQL_ROOT_PASSWORD dans l'environnement."
  exit 1
fi

log INFO "Version MariaDB actuelle:"
docker exec -i "$CONTAINER_NAME" mariadb -u"$DB_USER_EFFECTIVE" -p"$DB_PASSWORD_EFFECTIVE" -Nse "SELECT VERSION();"

log INFO "Diagnostic table mysql.proc (nombre de colonnes):"
docker exec -i "$CONTAINER_NAME" mariadb -u"$DB_USER_EFFECTIVE" -p"$DB_PASSWORD_EFFECTIVE" -Nse "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='mysql' AND TABLE_NAME='proc';" || true

if [[ "$CHECK_ONLY" == "true" ]]; then
  log INFO "Mode check-only: aucune modification effectuee."
  exit 0
fi

log INFO "Execution de mariadb-upgrade..."
# Utilise MYSQL_PWD pour eviter d'afficher le mot de passe dans les logs de la commande.
docker exec -i -e MYSQL_PWD="$DB_PASSWORD_EFFECTIVE" "$CONTAINER_NAME" \
  mariadb-upgrade -u"$DB_USER_EFFECTIVE" --force

log INFO "Redemarrage du conteneur $CONTAINER_NAME"
docker restart "$CONTAINER_NAME" >/dev/null

log INFO "Verification post-redemarrage: connexion MariaDB"
if ! docker exec -i "$CONTAINER_NAME" mariadb -u"$DB_USER_EFFECTIVE" -p"$DB_PASSWORD_EFFECTIVE" -Nse "SELECT 1;" >/dev/null; then
  log ERROR "MariaDB ne repond pas apres redemarrage"
  exit 1
fi

log INFO "Version MariaDB apres upgrade:"
docker exec -i "$CONTAINER_NAME" mariadb -u"$DB_USER_EFFECTIVE" -p"$DB_PASSWORD_EFFECTIVE" -Nse "SELECT VERSION();"

log INFO "Re-test mysql.proc (nombre de colonnes):"
docker exec -i "$CONTAINER_NAME" mariadb -u"$DB_USER_EFFECTIVE" -p"$DB_PASSWORD_EFFECTIVE" -Nse "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='mysql' AND TABLE_NAME='proc';" || true

TMP_DUMP="/tmp/${CONTAINER_NAME}_${TEST_DB}_upgrade_test_$$.sql"
trap 'rm -f "$TMP_DUMP"' EXIT

log INFO "Test dump avec routines/triggers sur '$TEST_DB'"
if docker exec -i "$CONTAINER_NAME" mariadb-dump -u"$DB_USER_EFFECTIVE" -p"$DB_PASSWORD_EFFECTIVE" \
  --databases "$TEST_DB" --skip-comments --single-transaction --routines --triggers > "$TMP_DUMP"; then
  if [[ -s "$TMP_DUMP" ]]; then
    log INFO "Test dump OK: $TMP_DUMP"
    rm -f "$TMP_DUMP"
  else
    log ERROR "Dump cree mais vide"
    exit 1
  fi
else
  log ERROR "Echec du test dump. Le probleme peut persister."
  exit 1
fi

log INFO "Correction terminee. Tu peux relancer ./backup_elkarbackup.sh --backup"
