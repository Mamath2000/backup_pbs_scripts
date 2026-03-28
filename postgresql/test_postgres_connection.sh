#!/bin/bash
set -euo pipefail

# Test de connexion vers PostgreSQL en utilisant la configuration du script de backup
# Usage: test_postgres_connection.sh [path/to/backup_postgres.conf]

log_info() {
    echo "$@"
}

log_debug() {
    if [[ "${LOG_LEVEL:-}" == "DEBUG" ]]; then
        echo "$@"
    fi
    return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-${SCRIPT_DIR}/backup_postgres.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Fichier de configuration introuvable: $CONFIG_FILE"
    echo "Passez le chemin en paramètre ou créez $CONFIG_FILE"
    exit 2
fi

source "$CONFIG_FILE"

if [[ -z "${DB_HOST:-}" || -z "${DB_PORT:-}" || -z "${DB_USER:-}" || -z "${DB_NAME:-}" ]]; then
    echo "Variables DB_HOST/DB_PORT/DB_USER/DB_NAME manquantes dans la configuration"
    exit 3
fi

log_info "Test de connexion PostgreSQL: host='${DB_HOST}', port=${DB_PORT}, db='${DB_NAME}', user='${DB_USER}'"

ok_tcp=false
ok_pg_isready=false
ok_psql=false
ok_pgdump=false

############################################
# Test TCP
############################################
if command -v nc >/dev/null 2>&1; then
    log_debug "Exécution: nc -z -w5 $DB_HOST $DB_PORT"
    if nc -z -w5 "$DB_HOST" "$DB_PORT" >/dev/null 2>&1; then
        log_info "TCP: OK"
        ok_tcp=true
    else
        log_info "TCP: ÉCHEC"
    fi
else
    log_debug "nc non disponible"
fi

############################################
# Test pg_isready
############################################
if command -v pg_isready >/dev/null 2>&1; then
    log_debug "Exécution: pg_isready -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"
    if pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t 5 >/dev/null 2>&1; then
        log_info "pg_isready: OK"
        ok_pg_isready=true
    else
        log_info "pg_isready: ÉCHEC"
    fi
else
    log_debug "pg_isready non installé"
fi

############################################
# Test psql
############################################
if command -v psql >/dev/null 2>&1; then
    out_tmp="/tmp/psql_out.$$"
    err_tmp="/tmp/psql_err.$$"
    rm -f "$out_tmp" "$err_tmp"

    log_debug "Exécution: psql SELECT 1"
    if timeout 10 psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -c "SELECT 1;" >"$out_tmp" 2>"$err_tmp"; then
        ok_psql=true
        log_info "psql: OK"
    else
        log_info "psql: ÉCHEC"
    fi

    if [[ "${LOG_LEVEL:-}" == "DEBUG" ]]; then
        echo "--- psql stdout ---"
        sed -n '1,200p' "$out_tmp"
        echo "--- psql stderr ---"
        sed -n '1,200p' "$err_tmp"
    fi

    rm -f "$out_tmp" "$err_tmp"
else
    log_debug "psql non installé"
fi

############################################
# Test pg_dump
############################################
if command -v pg_dump >/dev/null 2>&1; then
    out_tmp="/tmp/pgdump_out.$$"
    err_tmp="/tmp/pgdump_err.$$"
    rm -f "$out_tmp" "$err_tmp"

    log_debug "Exécution: pg_dump --schema-only"
    if timeout 15 pg_dump --host "$DB_HOST" --port "$DB_PORT" -U "$DB_USER" \
        --schema-only "$DB_NAME" >"$out_tmp" 2>"$err_tmp"; then
        ok_pgdump=true
        log_info "pg_dump: OK"
    else
        log_info "pg_dump: ÉCHEC"
    fi

    if [[ "${LOG_LEVEL:-}" == "DEBUG" ]]; then
        echo "--- pg_dump stdout ---"
        sed -n '1,200p' "$out_tmp"
        echo "--- pg_dump stderr ---"
        sed -n '1,200p' "$err_tmp"
    fi

    rm -f "$out_tmp" "$err_tmp"
else
    log_debug "pg_dump non installé"
fi

############################################
# Résultat final
############################################
if [[ "$ok_pgdump" == true ]]; then
    echo "RÉSULTAT: CONNEXION POSTGRES OK (pg_dump)"
    exit 0
fi

if [[ "$ok_psql" == true ]]; then
    echo "RÉSULTAT: CONNEXION POSTGRES OK (psql)"
    exit 0
fi

echo "RÉSULTAT: ÉCHEC DE CONNEXION À POSTGRES"
exit 5
