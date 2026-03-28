#!/bin/bash
set -euo pipefail

# Test de connexion vers PostgreSQL en utilisant la configuration du script de backup
# Usage: test_postgres_connection.sh [path/to/backup_postgres.conf]

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

echo "Test de connexion PostgreSQL: host='${DB_HOST}', port=${DB_PORT}, db='${DB_NAME}', user='${DB_USER}'"

ok=false

# Test TCP via nc si disponible
if command -v nc >/dev/null 2>&1; then
    echo -n "Vérification TCP (${DB_HOST}:${DB_PORT})... "
    if nc -z -w5 "$DB_HOST" "$DB_PORT" >/dev/null 2>&1; then
        echo "OK"
        ok_tcp=true
    else
        echo "ÉCHEC"
        ok_tcp=false
    fi
else
    echo "nc non disponible, saut du test TCP"
    ok_tcp=false
fi

# Test pg_isready si disponible
if command -v pg_isready >/dev/null 2>&1; then
    echo -n "pg_isready... "
    if pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t 5 >/dev/null 2>&1; then
        echo "OK"
        ok_pg_isready=true
    else
        echo "ÉCHEC"
        ok_pg_isready=false
    fi
else
    echo "pg_isready non installé, saut du test pg_isready"
    ok_pg_isready=false
fi

# Test d'authentification via psql
if command -v psql >/dev/null 2>&1; then
    echo "Test avec psql... (timeout 10s)"
    out_tmp="/tmp/psql_out.$$"
    err_tmp="/tmp/psql_err.$$"
    rm -f "$out_tmp" "$err_tmp"
    psql_rc=0
    if command -v timeout >/dev/null 2>&1; then
        if timeout 10 psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" >"$out_tmp" 2>"$err_tmp"; then
            psql_rc=0
        else
            psql_rc=$?
        fi
    else
        if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" >"$out_tmp" 2>"$err_tmp"; then
            psql_rc=0
        else
            psql_rc=$?
        fi
    fi

    echo "--- psql stdout ---"
    if [[ -s "$out_tmp" ]]; then
        sed -n '1,200p' "$out_tmp"
    else
        echo "(aucune sortie standard)"
    fi
    echo "--- psql stderr ---"
    if [[ -s "$err_tmp" ]]; then
        sed -n '1,200p' "$err_tmp"
    else
        echo "(aucune erreur)"
    fi

    if [[ $psql_rc -eq 0 ]]; then
        echo "psql: connexion et authentification OK"
        ok_psql=true
    else
        echo "psql: échec de la connexion ou de l'authentification (rc=$psql_rc)"
        ok_psql=false
    fi

    rm -f "$out_tmp" "$err_tmp"
else
    echo "psql non installé, saut du test psql"
    ok_psql=false
fi

# Test pg_dump (vérifie que pg_dump peut s'authentifier et démarrer un dump)
if command -v pg_dump >/dev/null 2>&1; then
    echo "Test avec pg_dump (schema-only) ... (timeout 15s)"
    out_tmp="/tmp/pgdump_out.$$"
    err_tmp="/tmp/pgdump_err.$$"
    rm -f "$out_tmp" "$err_tmp"
    pgdump_rc=0
    if command -v timeout >/dev/null 2>&1; then
        if timeout 15 pg_dump --host "$DB_HOST" --port "$DB_PORT" -U "$DB_USER" --schema-only "$DB_NAME" >"$out_tmp" 2>"$err_tmp"; then
            pgdump_rc=0
        else
            pgdump_rc=$?
        fi
    else
        if pg_dump --host "$DB_HOST" --port "$DB_PORT" -U "$DB_USER" --schema-only "$DB_NAME" >"$out_tmp" 2>"$err_tmp"; then
            pgdump_rc=0
        else
            pgdump_rc=$?
        fi
    fi

    echo "--- pg_dump stdout ---"
    if [[ -s "$out_tmp" ]]; then
        sed -n '1,200p' "$out_tmp"
    else
        echo "(aucune sortie standard)"
    fi
    echo "--- pg_dump stderr ---"
    if [[ -s "$err_tmp" ]]; then
        sed -n '1,200p' "$err_tmp"
    else
        echo "(aucune erreur)"
    fi

    if [[ $pgdump_rc -eq 0 ]]; then
        echo "pg_dump: test de dump réussi"
        ok_pgdump=true
    else
        echo "pg_dump: échec (rc=$pgdump_rc)"
        ok_pgdump=false
    fi

    rm -f "$out_tmp" "$err_tmp"
else
    echo "pg_dump non installé, saut du test pg_dump"
    ok_pgdump=false
fi

# Résultat final: privilégier pg_dump (vérifie auth + capacité de dump)
if [[ "${ok_pgdump:-false}" == "true" ]]; then
    echo "RÉSULTAT: CONNEXION POSTGRES OK (pg_dump)"
    exit 0
fi

if [[ "${ok_psql:-false}" == "true" ]]; then
    echo "RÉSULTAT: CONNEXION POSTGRES OK (psql)"
    exit 0
fi

echo "RÉSULTAT: ÉCHEC DE CONNEXION À POSTGRES"
exit 5
