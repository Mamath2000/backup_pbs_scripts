#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/libs/logs.sh"
source "${SCRIPT_DIR}/libs/config.sh"
source "${SCRIPT_DIR}/libs/cli.sh"
source "${SCRIPT_DIR}/libs/tools.sh"
source "${SCRIPT_DIR}/libs/pbs_client.sh"
source "${SCRIPT_DIR}/libs/mqtt.sh"
source "${SCRIPT_DIR}/libs/backup_runner.sh"

cli::parse "$@"
config::load
logs::init

if [[ "$MODE" == "check" ]]; then
    pbs::check_connection
    exit $?
fi

backup::run

logs::info "Backup terminé"
