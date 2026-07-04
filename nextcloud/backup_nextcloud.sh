#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLI_BACKUP_SCRIPT="${REPO_ROOT}/cli/backup_pbs.sh"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/backup_nextcloud.conf"
LOCK_FILE="${SCRIPT_DIR}/.backup_nextcloud.lock"

MODE=""
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
LOG_FILE=""
WORK_RUN_DIR=""
RUN_TIMESTAMP=""
DOCKER_ID=""
LOCK_ACQUIRED=false

USER_ENTRY_PATH=""
USER_ENTRY_DATASTORE=""

source "${SCRIPT_DIR}/libs/logs.sh"
source "${SCRIPT_DIR}/libs/tools.sh"
source "${SCRIPT_DIR}/libs/cli.sh"
source "${SCRIPT_DIR}/libs/config.sh"
source "${SCRIPT_DIR}/libs/runtime.sh"
source "${SCRIPT_DIR}/libs/docker_ops.sh"
source "${SCRIPT_DIR}/libs/backup_jobs.sh"
source "${SCRIPT_DIR}/libs/backup_runner.sh"

main() {
    nextcloud::cli::parse "$@"
    nextcloud::logs::init
    nextcloud::runtime::check_dependencies
    nextcloud::config::load

    if [[ "$MODE" == "check" ]]; then
        nextcloud::jobs::cli_check
        exit 0
    fi

    nextcloud::runtime::acquire_lock
    trap nextcloud::runtime::cleanup EXIT
    nextcloud::runner::run_backup
}

main "$@"