---
title: CLI — Bibliothèques
sidebar_label: CLI (libs)
---

Ce document présente les bibliothèques fournies dans le répertoire cli/libs et décrit les fonctions principales et leur rôle.

| Bibliothèque | Fonctions principales | Rôle |
| --- | --- | --- |
| cli/libs/cli.sh | `cli::usage`, `cli::parse` | Analyse et validation des arguments en ligne de commande (modes, options, affichage d'aide). |
| cli/libs/config.sh | `config::load` | Chargement du fichier de configuration (`backup.conf`), vérification des permissions (600) et initialisation des variables globales (PBS, MQTT, etc.). |
| cli/libs/logs.sh | `logs::init`, `logs::log`, `logs::info`, `logs::error`, `logs::warn` | Initialisation du logging (fichier de log par backup), formatage des messages, écriture via `tee`. |
| cli/libs/tools.sh | `require_var`, `sanitize_name` | Outils utilitaires : validation de variables requises et nettoyage/sanitarisation de noms pour IDs/fichiers. |
| cli/libs/backup_runner.sh | `backup::run`, `backup::cleanup` | Orchestration du processus de sauvegarde : préparation des arguments, construction des specs PBS, gestion des traps et publications MQTT. |
| cli/libs/mqtt.sh | `mqtt::publish_discovery`, `mqtt::publish_metrics` | Construction des payloads JSON et publication vers Home Assistant via `mosquitto_pub` (discovery + métriques). |
| cli/libs/pbs_client.sh | `pbs::build_repository_full`, `pbs::build_specs`, `pbs::run_apt`, `pbs::run_docker`, `pbs::run_backup`, `pbs::check_connection` | Prépare les specs/mounts pour le client PBS et exécute `proxmox-backup-client` soit natif (apt) soit via Docker ; fournis aussi une commande de test de connexion. |

**Points d'intégration / usage**

- Ces fichiers sont pensés pour être sourcés depuis le script principal via `SCRIPT_DIR`, par exemple : `source "${SCRIPT_DIR}/libs/cli.sh"`.
- Variables fréquemment attendues par les libs : `BACKUP_NAME`, `BACKUP_DIR`, `PBS_REPOSITORY`, `PBS_PASSWORD`/`PBS_PASSWORD_FILE`, `PBS_CLIENT_MODE`, `MQTT_*`, `PBS_DATASTORE_DEFAULT`, `EXTRA_ARGS`, etc.
- Les fonctions suivent le préfixe `module::function` pour éviter les collisions et faciliter l'import dans d'autres scripts.

Si vous souhaitez que j'ajoute une section détaillée (par fonction, avec exemples d'utilisation), dites-le et je la génère.
