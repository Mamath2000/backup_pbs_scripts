#!/bin/bash
set -euo pipefail

# restore_cluster_simple.sh
# Usage: restore_cluster_simple.sh /path/to/cluster_backup.tar /var/lib/postgresql/13/main
# Extremely simple, interactive restore:
# - requires root
# - moves current PGDATA to PGDATA.bak.TIMESTAMP
# - extracts tar into PGDATA
# - fixes ownership to postgres:postgres
# - attempts to start postgres via systemctl/service

if [[ $(id -u) -ne 0 ]]; then
  echo "Ce script doit être exécuté en tant que root (sudo)."
  exit 2
fi

BACKUP_TAR="${1:-}"
PGDATA="${2:-}"
SERVICE_NAME="${3:-postgresql}"

if [[ -z "$BACKUP_TAR" || -z "$PGDATA" ]]; then
  echo "Usage: $0 /chemin/vers/backup_cluster.tar /chemin/vers/PGDATA [service_name]"
  exit 1
fi

if [[ ! -f "$BACKUP_TAR" ]]; then
  echo "Archive de backup introuvable: $BACKUP_TAR"
  exit 1
fi

if [[ ! -d "$PGDATA" ]]; then
  echo "Répertoire PGDATA introuvable: $PGDATA"
  exit 1
fi

TS=$(date +%Y%m%d%H%M%S)
BACKUP_OLD="${PGDATA}.bak.${TS}"

echo "=== Restauration du cluster PostgreSQL ==="
echo "Archive : $BACKUP_TAR"
echo "PGDATA  : $PGDATA"
echo "Ancien PGDATA sera déplacé vers : $BACKUP_OLD"

read -p "Confirmez-vous (oui pour continuer) ? " ans
if [[ "$ans" != "oui" ]]; then
  echo "Annulé."
  exit 0
fi

# Stop postgres (try systemctl, then service)
echo "Arrêt du service PostgreSQL (si actif)..."
if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null || systemctl status "$SERVICE_NAME" &>/dev/null; then
  systemctl stop "$SERVICE_NAME" || true
else
  service "$SERVICE_NAME" stop || true
fi

# Move current PGDATA
echo "Déplacement de l'ancien PGDATA vers $BACKUP_OLD"
mv "$PGDATA" "$BACKUP_OLD"
mkdir -p "$PGDATA"

# Extract archive into PGDATA
echo "Extraction de l'archive dans $PGDATA (peut prendre du temps)..."
tar -xpf "$BACKUP_TAR" -C "$PGDATA"

# Ensure ownership and permissions
echo "Réglage des permissions (postgres:postgres)..."
chown -R postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

# Start postgres
echo "Démarrage du service PostgreSQL..."
if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null || systemctl status "$SERVICE_NAME" &>/dev/null; then
  systemctl start "$SERVICE_NAME" || true
else
  service "$SERVICE_NAME" start || true
fi

echo "Restauration terminée. Vérifiez les logs PostgreSQL si nécessaire."

echo "Si tout est OK, vous pouvez supprimer l'ancien PGDATA : $BACKUP_OLD"

exit 0
