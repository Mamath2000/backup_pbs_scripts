#!/usr/bin/env bash
# Build script moved into pbs_client/ to build the unified PBS client image

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "ERREUR: docker-compose.yml introuvable: $COMPOSE_FILE" >&2
    exit 1
fi

docker compose -f "$COMPOSE_FILE" --project-directory "$COMPOSE_DIR" build

echo "OK: image construite (proxmox-pbs-client:latest)"
