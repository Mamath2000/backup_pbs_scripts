---
title: Sauvegarde PostgreSQL — backup_postgres.sh
sidebar_label: PostgreSQL Backup
---

Résumé
-------

`backup_postgres.sh` est le script principal pour effectuer des sauvegardes PostgreSQL. Principales caractéristiques :

- Modes de sauvegarde : `cluster` (pg_basebackup) et `perdb` (pg_dump par base).
- Publication de métriques et discovery vers Home Assistant via MQTT.
- Option d'envoi vers Proxmox Backup Server (PBS) (mode `apt` ou `docker`).
- Mode de test (`--check`) et simulation (`--dummy-run`).
- Gestion de verrou (évite exécutions concurrentes) et logging détaillé.

Fichiers (libs & modules)
-------------------------

| Fichier | Fonctions principales | Rôle |
| --- | --- | --- |
| postgresql/libs/cli.sh | `cli::parse`, `cli::usage` | Analyse des options CLI : `--backup`, `--check`, `--dummy-run`. |
| postgresql/libs/config.sh | `config::load` | Chargement du fichier de configuration passé en argument ; vérification des permissions strictes. |
| postgresql/libs/logs.sh | `logs::init`, `logs::log`, `logs::info`, `logs::debug`, `logs::warn`, `logs::error` | Initialisation et rotation basique des logs ; helpers de logging. |
| postgresql/libs/lock.sh | `lock::check`, `lock::cleanup` | Gestion du verrou pour empêcher les instances concurrentes. |
| postgresql/libs/tools.sh | `tools::check_dependencies`, `tools::check_config` | Vérification des dépendances nécessaires (pg_dump/pg_basebackup, jq, mosquitto_pub, proxmox-backup-client) et validations de configuration. |
| postgresql/modules/mqtt_discovery.sh | `mqtt::init_backup`, `mqtt::finalize_backup`, `mqtt::publish_mqtt_discovery`, `mqtt::publish_metrics`, `json::build_discovery_payload`, `json::build_metrics_payload` | Construction des payloads JSON et publication MQTT (discovery + métriques unifiées). |
| postgresql/modules/pbs_backup.sh | `pbs::is_enabled`, `pbs::compute_backup_id`, `pbs::exec_backup`, `pbs::backup_file`, `pbs::run_backup` | Prépare l'ID PBS, le staging des fichiers, et exécute l'envoi vers PBS (docker ou natif), en masquant les secrets dans les logs. |
| postgresql/modules/db_backup.sh | `backup::create_directory`, `backup::prepare_paths`, `backup::perform_database_dump`, `backup::perform_cluster_dump`, `backup::create_dummy`, `backup::verify_dummy`, `backup::verify_integrity`, `backup::compress`, `backup::cleanup_old` | Fonctions de dump pour `pg_dump` (perdb) et `pg_basebackup` (cluster), compression locale et nettoyage des anciennes sauvegardes. |
| postgresql/modules/runner.sh | `runner::run_generic` | Orchestration d'un job de backup (mesure du temps, publication MQTT, appel des dumps, envoi PBS, compression). |

Flux principal
--------------

1. Vérification des dépendances : `tools::check_dependencies` et validations `tools::check_config`.
2. Lecture des options CLI via `cli::parse` (mode `backup`, `check`, `dummy-run`).
3. Vérification du verrou (`lock::check`) — le mode `check` contourne le verrou.
4. Chargement de la configuration (`config::load`) et initialisation du logging (`logs::init`).
5. `main()` détermine le `BACKUP_MODE` (`cluster` ou `perdb`) et appelle `runner::run_generic` qui :
   - calcule `PBS_BACKUP_ID` (`pbs::compute_backup_id`), prépare les chemins (`backup::prepare_paths`), publie la discovery MQTT (`mqtt::init_backup`);
   - appelle la fonction de dump (`backup::perform_cluster_dump` ou `backup::perform_database_dump`);
   - envoie le fichier vers PBS (`pbs::run_backup` / `pbs::backup_file`) si activé;
   - compresse le fichier (`backup::compress`) et nettoie les anciennes sauvegardes (`backup::cleanup_old`);
   - publie les métriques finales via MQTT (`mqtt::publish_metrics`).

Variables de configuration importantes
------------------------------------

- `DB_HOST`, `DB_PORT`, `DB_USER` : connexion PostgreSQL (auth via ~/.pgpass recommandée). Le script refuse `DB_PASSWORD` en clair.
- `BACKUP_DIR` : répertoire local de stockage des dumps.
- `BACKUP_MODE` : `cluster` (pg_basebackup) ou `perdb` (pg_dump). Par défaut `cluster`.
- `BACKUP_TARGETS` : CSV des bases à sauvegarder en mode `perdb`.
- `DAYS_TO_KEEP` : rétention locale (suppression des archives plus anciennes).
- `COMPRESSION_ENABLED`, `COMPRESSION_LEVEL` : contrôle la compression gzip locale.
- `VERIFY_BACKUP` : si `true`, exécute des vérifications d'intégrité après dump.
- `PBS_ENABLED`, `PBS_REPOSITORY`, `PBS_DATASTORE`, `PBS_CLIENT_MODE` (`apt`|`docker`), `PBS_PASSWORD`/`PBS_PASSWORD_FILE` : options d'envoi vers Proxmox Backup Server.
- `MQTT_ENABLED`, `MQTT_HOST`, `MQTT_PORT`, `MQTT_BASE_TOPIC`, `MQTT_USER`, `MQTT_PASSWORD` : publication Home Assistant.

Modes CLI
---------

- `--backup` : exécution normale (par défaut).
- `--check` : tests (vérification PBS, configuration) ; contourne le verrou.
- `--dummy-run` : crée des fichiers de test (utilisé pour valider le pipeline sans accès DB). Active `TEST_MODE`.

Exemples
--------

Vérifier la configuration / connexion PBS :

```bash
./postgresql/backup_postgres.sh --check
```

Exécuter une sauvegarde normale :

```bash
./postgresql/backup_postgres.sh --backup
```

Notes importantes
---------------

- Le script attend une authentification PostgreSQL via `~/.pgpass` (ne pas stocker `DB_PASSWORD` en clair dans la conf).
- Les logs sont écrits dans `SCRIPT_DIR/logs` et le fichier de verrou `SCRIPT_DIR/.backup_postgres.lock` est utilisé pour empêcher exécutions concurrentes.
- Les modules PBS prennent soin de masquer `PBS_PASSWORD` dans les logs et d'utiliser un répertoire de staging avant envoi.
Voir aussi

- [CLI — Bibliothèques](cli_libs.md) : présentation détaillée des bibliothèques du CLI et description des fonctions.

Compatibilité Docusaurus
------------------------

Ce fichier utilise le frontmatter Docusaurus (`title` et `sidebar_label`) et est prêt à être placé dans le dossier `docs/`.
