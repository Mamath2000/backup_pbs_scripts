#!/usr/bin/env bash
# Installation du proxmox-backup-client via APT (Debian)

set -euo pipefail

if [[ ! -f /etc/os-release ]]; then
    echo "ERREUR: /etc/os-release introuvable" >&2
    exit 1
fi

# shellcheck source=/dev/null
source /etc/os-release

if [[ "${ID:-}" != "debian" ]]; then
    echo "ERREUR: script prévu pour Debian (ID=${ID:-inconnu})" >&2
    exit 1
fi

CODENAME="${VERSION_CODENAME:-}"
if [[ -z "$CODENAME" ]]; then
    echo "ERREUR: VERSION_CODENAME introuvable" >&2
    exit 1
fi

GPG_FILE="proxmox-release-${CODENAME}.gpg"
GPG_URL="https://enterprise.proxmox.com/debian/${GPG_FILE}"
LIST_FILE="/etc/apt/sources.list.d/pbs-client.list"

curl -fsSLO "$GPG_URL"
sudo mv "$GPG_FILE" /etc/apt/trusted.gpg.d

echo "deb http://download.proxmox.com/debian/pbs-client ${CODENAME} main" | sudo tee "$LIST_FILE" >/dev/null

sudo apt update
sudo apt install -y proxmox-backup-client

echo "OK: proxmox-backup-client installé"