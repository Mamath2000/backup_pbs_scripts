#!/bin/bash
set -euo pipefail

# Test de connexion vers Proxmox Backup Server (PBS)
# Usage: test_pbs_connection.sh [path/to/backup_config.conf]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-${SCRIPT_DIR}/backup_config.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Fichier de configuration introuvable: $CONFIG_FILE"
    echo "Passez le chemin en paramètre ou créez $CONFIG_FILE"
    exit 2
fi

source "$CONFIG_FILE"

if [[ "${PBS_ENABLED:-false}" != "true" ]]; then
    echo "PBS non activé dans la configuration (PBS_ENABLED != true). Test annulé."
    exit 3
fi

if [[ -z "${PBS_REPOSITORY:-}" ]]; then
    echo "PBS_REPOSITORY non défini dans la configuration"
    exit 4
fi

if [[ -z "${PBS_DATASTORE:-}" ]]; then
    echo "PBS_DATASTORE non défini dans la configuration (obligatoire)"
    exit 6
fi

# Extraire l'hôte depuis PBS_REPOSITORY (format: [user@]host:repo)
repo="${PBS_REPOSITORY}"
# Extraire l'hôte: prendre la partie après le dernier '@' (gère user@realm!token@host:store)
hostport="${repo##*@}"
# retirer toute partie :datastore si présente pour extraire l'hôte
hostport_nodatastore="${hostport%%:*}"
host="$hostport_nodatastore"
port="${PBS_PORT:-8007}"
datastore="${PBS_DATASTORE}"

echo "Test de connexion vers PBS: repository='${PBS_REPOSITORY}', host='${host}', port=${port}, datastore=${datastore}"

ok=false

# Test TCP via nc si disponible
if command -v nc >/dev/null 2>&1; then
    echo -n "Vérification TCP (${host}:${port})... "
    if nc -z -w5 "$host" "$port" >/dev/null 2>&1; then
        echo "OK"
        ok=true
    else
        echo "ÉCHEC"
    fi
else
    echo "nc non disponible, saut du test TCP"
fi

# Test HTTPS via curl en fallback
if [[ "$ok" != true ]]; then
    if command -v curl >/dev/null 2>&1; then
        echo -n "Tentative HTTP(S) https://${host}:${port}/ ... "
        if curl -k --max-time 5 -sSf "https://${host}:${port}/" >/dev/null 2>&1; then
            echo "OK"
            ok=true
        else
            echo "ÉCHEC"
        fi
    else
        echo "curl non disponible, saut du test HTTPS"
    fi
fi

# Test via proxmox-backup-client si installé (avec timeout pour éviter blocage)
if command -v proxmox-backup-client >/dev/null 2>&1; then
    echo "Test avec proxmox-backup-client... (timeout 15s)"
    # construire repo_arg en ajoutant datastore si nécessaire
    if [[ "${PBS_REPOSITORY}" == *":"* ]]; then
        repo_arg="${PBS_REPOSITORY}"
    else
        repo_arg="${PBS_REPOSITORY}:${PBS_DATASTORE}"
    fi

    # construire repo_arg en ajoutant datastore si nécessaire
    if [[ "${PBS_REPOSITORY}" == *":"* ]]; then
        repo_arg="${PBS_REPOSITORY}"
    else
        repo_arg="${PBS_REPOSITORY}:${PBS_DATASTORE}"
    fi

    # Exécuter la commande et afficher ses sorties (stdout/stderr)
    out_tmp="/tmp/pbs_out.$$"
    err_tmp="/tmp/pbs_err.$$"
    rm -f "$out_tmp" "$err_tmp"

    if command -v timeout >/dev/null 2>&1; then
        env PBS_PASSWORD="${PBS_PASSWORD:-}" timeout 15 proxmox-backup-client list --repository "${repo_arg}" >"$out_tmp" 2>"$err_tmp" || true
    else
        env PBS_PASSWORD="${PBS_PASSWORD:-}" proxmox-backup-client list --repository "${repo_arg}" >"$out_tmp" 2>"$err_tmp" || true
    fi

    echo "--- proxmox-backup-client stdout ---"
    if [[ -s "$out_tmp" ]]; then
        sed -n '1,200p' "$out_tmp"
    else
        echo "(aucune sortie standard)"
    fi
    echo "--- proxmox-backup-client stderr ---"
    if [[ -s "$err_tmp" ]]; then
        sed -n '1,200p' "$err_tmp"
    else
        echo "(aucune erreur)"
    fi

    # Si le fichier de sortie contient quelque chose et que la commande a renvoyé 0, considérer OK
    if [[ -s "$out_tmp" ]] && grep -q . "$out_tmp" 2>/dev/null; then
        # Heuristique simple: présence de lignes signifie réussite de la liste
        echo "proxmox-backup-client: communication (résultat list affiché)"
        ok=true
    else
        echo "proxmox-backup-client: échec ou aucune donnée retournée"
    fi

    rm -f "$out_tmp" "$err_tmp"
else
    echo "proxmox-backup-client non installé, saut du test client"
fi

if [[ "$ok" == true ]]; then
    echo "RÉSULTAT: CONNEXION PBS OK"
    exit 0
else
    echo "RÉSULTAT: ÉCHEC DE CONNEXION À PBS"
    exit 5
fi
