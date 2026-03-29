---
id: backup_pbs
title: backup_pbs.sh — CLI générique
sidebar_label: Sauvegarde PBS
slug: /backup-pbs
---

# `cli/backup_pbs.sh` — Sauvegarde générique PBS

Script universel pour sauvegarder n'importe quel dossier local vers Proxmox Backup Server via `proxmox-backup-client` (apt ou Docker).

---

## Ce qui est sauvegardé

Un **unique répertoire** (obligatoire via `-d`), envoyé comme archive `.pxar` dans un snapshot PBS. Des exclusions peuvent être ajoutées via `-e`.

Le nom de l'archive dans le snapshot est dérivé du nom du dossier sauvegardé (caractères non alphanumériques remplacés par `_`).

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


## Utilisation

### Sauvegarde

```bash
./backup_pbs.sh "nom-backup" -d /chemin/a/sauvegarder [-e /chemin/exclu]...
```

| Argument | Obligatoire | Description |
|----------|-------------|-------------|
| `"nom-backup"` | ✓ | Identifiant du backup (utilisé comme `--backup-id` PBS et dans le nom du log) |
| `-d /chemin` | ✓ | Répertoire source à sauvegarder (un seul) |
| `-e /chemin` | — | Chemin ou pattern à exclure (répétable) |
| `--datastore NAME` | — | Datastore PBS cible (surcharge `PBS_DATASTORE_DEFAULT`) |

**Exemples :**
```bash
./backup_pbs.sh host-prod -d /etc
./backup_pbs.sh host-prod -d /etc -e /etc/ssl -e /etc/hostname
./backup_pbs.sh host-prod -d /home --datastore ds2
```

### Test de connexion

```bash
./backup_pbs.sh --check [--datastore NAME] [--namespace NAME]
```

Vérifie la connexion à PBS en listant les snapshots disponibles. N'effectue aucune sauvegarde.

---

## Configuration — `cli/backup.conf`

Le fichier doit exister et avoir les droits **600** (vérifié au démarrage).

### Variables obligatoires

| Variable | Description | Exemple |
|----------|-------------|---------|
| `PBS_REPOSITORY` | Adresse PBS **sans datastore** (`user@realm@host`) | `user@pbs@192.168.1.10` |
| `PBS_DATASTORE_DEFAULT` | Datastore par défaut | `ds3` |
| `PBS_PASSWORD` | Mot de passe PBS (> 40 caractères) | `…` |

### Variables optionnelles

| Variable | Défaut | Description |
|----------|--------|-------------|
| `PBS_FINGERPRINT` | — | Empreinte TLS du serveur PBS |
| `PBS_NAMESPACE` | — | Namespace PBS (ex: `Hosts`) |
| `PBS_CLIENT_MODE` | `apt` | `apt` ou `docker` |
| `PBS_DOCKER_IMAGE` | `proxmox-pbs-client:latest` | Image Docker à utiliser en mode `docker` |
| `PBS_CHANGE_DETECTION_MODE` | — | Mode de détection des changements (`legacy`, `data`, `metadata`) |
| `PBS_CLIENT_EXTRA_ARGS` | — | Arguments supplémentaires passés à `proxmox-backup-client` |
| `MQTT_ENABLED` | `false` | Activer les notifications MQTT |
| `MQTT_HOST` | `localhost` | Adresse du broker MQTT |
| `MQTT_PORT` | `1883` | Port MQTT |
| `MQTT_USER` | — | Utilisateur MQTT |
| `MQTT_PASSWORD` | — | Mot de passe MQTT |

### Construction de `PBS_REPOSITORY_FULL`

Le script construit la chaîne complète au démarrage :

```
PBS_REPOSITORY_FULL = PBS_REPOSITORY : DATASTORE
```

Le datastore est déterminé dans cet ordre de priorité :
1. `--datastore NAME` (CLI)
2. `PBS_DATASTORE_DEFAULT` (conf)
3. `backup` (fallback)

---

## Client Docker PBS

Quand `PBS_CLIENT_MODE=docker`, le script utilise l'image `proxmox-pbs-client:latest` construite depuis `pbs_client/` à la racine du dépôt.

Si l'image est absente, elle est **automatiquement construite** via `pbs_client/build_pbs_client.sh`.

**Construction manuelle :**
```bash
cd pbs_client/
./build_pbs_client.sh
# ou
docker compose build
```

En mode Docker, le répertoire source est monté en lecture seule dans le conteneur :
```
BACKUP_DIR → /source (ro)
```

---

## Logs

Tous les logs (stdout + stderr du script et des commandes exécutées) sont redirigés vers :

```
cli/logs/backup_<nom-sanitisé>.log
```

Le répertoire `logs/` est créé automatiquement. Le log est également affiché dans le terminal.

---

## Sécurité PBS

```bash
# Droits sur le fichier de configuration
chmod 600 cli/backup.conf

# Obtenir le fingerprint du certificat PBS
openssl s_client -connect <pbs_host>:8007 < /dev/null \
  | openssl x509 -noout -fingerprint -sha256
```

**Permissions PBS recommandées pour l'utilisateur dédié :**
- Rôle `backup` sur `/datastore/<nom>` (pour écrire des snapshots)
- Rôle `audit` sur `/datastore/<nom>` (pour lister/vérifier)

---

## MQTT / Home Assistant

Quand `MQTT_ENABLED=true`, le script publie :
- Une **découverte automatique** du device (`homeassistant/device/backup/<id>/config`)
- Un **état JSON** après chaque backup (`backup/<id>/state`) contenant : statut, durée, timestamp, message d'erreur

---

## Cron

```cron
0 2 * * * /chemin/vers/cli/backup_pbs.sh host-prod -d /etc >> /dev/null 2>&1
```

Les logs sont dans `cli/logs/backup_host-prod.log`.

---

## Dépendances

| Outil | Mode | Obligatoire |
|-------|------|-------------|
| `proxmox-backup-client` | `apt` | ✓ |
| `docker` | `docker` | ✓ |
| `mosquitto_pub` | — | Si `MQTT_ENABLED=true` |
