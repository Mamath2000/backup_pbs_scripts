---
id: backup_nextcloud
title: backup_nextcloud.sh — Sauvegarde Nextcloud AIO
sidebar_label: Nextcloud AIO
slug: /backup-nextcloud
---

# `nextcloud/backup_nextcloud.sh` — Sauvegarde Nextcloud AIO

Script dédié à la sauvegarde de l'instance **Nextcloud All-In-One** (PostgreSQL + config + données + sources) vers Proxmox Backup Server via Docker.

---

## Ce qui est sauvegardé

| Archive PBS | Source | Description |
|-------------|--------|-------------|
| `nextcloud-aio.pxar` | Staging dir (BACKUP_DIR) | Dump SQL + config.php + metadata.json |
| `nextcloud-aio-src.pxar` | `NEXTCLOUD_AIO_SOURCE_PATH` | Répertoire Docker Nextcloud AIO (volumes, config, mastercontainer…) |
| `nextcloud-data.pxar` | `NEXTCLOUD_DATA_PATH` | Données utilisateurs Nextcloud |

> **Mode `--dummy-run`** : `nextcloud-data.pxar` est remplacé par un dossier temporaire vide pour tester le backup sans transférer les données.

### Exclusions dans `nextcloud-aio-src.pxar`

| Pattern | Raison |
|---------|--------|
| `/ncaio/backup` | Évite de doubler les archives locales |
| `/ncaio/mastercontainer` | Fichiers runtime du mastercontainer (non nécessaires) |

---

## Étapes du backup

```
1. Vérification config       — conf, droits, dépendances
2. Lock fichier              — .backup_nextcloud.lock dans SCRIPT_DIR
3. Dump PostgreSQL           — docker exec <DOCKER_CONTAINER_NAME> pg_dump
                               → BACKUP_DIR/YYYYMMDDHHMM_nextcloud_backup.sql
4. Export config.php         — docker run alpine : copie depuis volume Nextcloud
                               → BACKUP_DIR/YYYYMMDDHHMM_nextcloud_config.php
5. Nettoyage local SQL       — suppression des anciens dumps (DAYS_TO_KEEP / MAX_LOCAL_BACKUPS)
6. Nettoyage local config    — suppression des anciennes config.php
7. Staging dir               — création sous BACKUP_DIR/ avec :
                                 • fichier SQL le plus récent (symlink ou copie)
                                 • fichier config.php le plus récent
                                 • metadata.json
8. Sauvegarde PBS            — docker run proxmox-pbs-client:latest backup
                               nextcloud-aio.pxar:/data
                               nextcloud-aio-src.pxar:/ncaio
                               nextcloud-data.pxar:/ncdata
9. Nettoyage staging         — suppression du répertoire temporaire
10. Notification MQTT        — si MQTT_ENABLED=true
11. Libération lock
```

---

## Configuration — `nextcloud/backup_nextcloud.conf`

Le fichier doit avoir les droits **600** (vérifié au démarrage).

### Variables obligatoires

| Variable | Description | Exemple |
|----------|-------------|---------|
| `PBS_REPOSITORY` | Adresse PBS **sans datastore** (`user@realm@host`) | `user@pbs@192.168.1.10` |
| `PBS_DATASTORE_DEFAULT` | Datastore PBS cible | `ds0` |
| `PBS_PASSWORD` | Mot de passe PBS (> 40 caractères) | `…` |
| `PBS_BACKUP_ID` | Identifiant du snapshot PBS | `nextcloud-aio` |
| `NEXTCLOUD_AIO_SOURCE_PATH` | Répertoire de l'installation Nextcloud AIO | `/mnt/user/docker/nextcloud-aio` |
| `NEXTCLOUD_DATA_PATH` | Répertoire des données utilisateurs | `/mnt/user/ncdata` |
| `DOCKER_CONTAINER_NAME` | Nom du conteneur PostgreSQL | `nextcloud-aio-database` |
| `DB_USER` | Utilisateur PostgreSQL | `nextcloud` |
| `DB_NAME` | Nom de la base de données | `nextcloud_database` |
| `BACKUP_DIR` | Répertoire de dépôt local (dumps, staging) | `/mnt/user/docker/nextcloud-aio/backup/` |

### Variables optionnelles

| Variable | Défaut | Description |
|----------|--------|-------------|
| `PBS_FINGERPRINT` | — | Empreinte TLS du serveur PBS |
| `PBS_NAMESPACE` | — | Namespace PBS (ex: `Hosts`) |
| `NEXTCLOUD_VOLUME_NAME` | — | Nom du volume Docker Nextcloud (pour export config.php) |
| `DAYS_TO_KEEP` | `10` | Rétention des dumps locaux (jours) |
| `MAX_LOCAL_BACKUPS` | `2` | Nombre max de dumps locaux conservés |
| `MQTT_ENABLED` | `false` | Activer les notifications MQTT |
| `MQTT_HOST` | `localhost` | Adresse du broker MQTT |
| `MQTT_PORT` | `1883` | Port MQTT |
| `MQTT_USER` | — | Utilisateur MQTT |
| `MQTT_PASSWORD` | — | Mot de passe MQTT |
| `LOG_LEVEL` | `INFO` | Niveau de log (`DEBUG`, `INFO`, `WARNING`, `ERROR`) |

> **Note :** `COMPRESSION_LEVEL` est ignoré (forcé à `0` dans le script). PBS assure la compression nativement.

---

## Construction de `PBS_REPOSITORY_FULL`

La construction est **intelligente** pour assurer la compatibilité avec d'anciens fichiers de conf :

```
Si --datastore en CLI               → PBS_REPOSITORY (sans datastore) : DATASTORE_CLI
Si PBS_REPOSITORY contient ":"      → PBS_REPOSITORY utilisé tel quel (compat)
Si PBS_DATASTORE_DEFAULT défini     → PBS_REPOSITORY : PBS_DATASTORE_DEFAULT
Sinon                               → ERREUR : datastore obligatoire
```

**Exemple (conf actuelle) :**
```
PBS_REPOSITORY="user@pbs@192.168.1.10"
PBS_DATASTORE_DEFAULT="ds0"
→ PBS_REPOSITORY_FULL="user@pbs@192.168.1.10:ds0"
```

---

## Client Docker PBS

L'image `proxmox-pbs-client:latest` est utilisée pour exécuter `proxmox-backup-client` sans installation système.

Si l'image est absente, elle est **automatiquement construite** depuis `pbs_client/`.

**Construction manuelle :**
```bash
cd pbs_client/
./build_pbs_client.sh
```

La commande Docker exécutée lors du backup :
```bash
docker run --rm --network host \
  -e PBS_REPOSITORY="..." \
  -e PBS_PASSWORD="..." \
  [-e PBS_FINGERPRINT="..."] \
  -v "$STAGING_DIR":/data:ro \
  -v "$NEXTCLOUD_AIO_SOURCE_PATH":/ncaio:ro \
  -v "$NEXTCLOUD_DATA_PATH":/ncdata:ro \
  proxmox-pbs-client:latest \
  backup \
    nextcloud-aio.pxar:/data \
    nextcloud-aio-src.pxar:/ncaio \
    nextcloud-data.pxar:/ncdata \
    --backup-id "$PBS_BACKUP_ID" \
    --backup-type host \
    [--ns "$PBS_NAMESPACE"] \
    --repository "$PBS_REPOSITORY_FULL" \
    --exclude /ncaio/backup \
    --exclude /ncaio/mastercontainer
```

---

## Test de connexion

```bash
./backup_nextcloud.sh --check [--datastore NAME] [--namespace NAME]
```

Exécute `proxmox-backup-client list` via Docker pour vérifier l'accès au datastore PBS. Affiche la liste des snapshots existants.

---

## Mode Dummy Run

```bash
./backup_nextcloud.sh --backup --dummy-run
```

Effectue toutes les étapes sauf l'envoi de `NEXTCLOUD_DATA_PATH` vers PBS (remplacé par un dossier vide). Utile pour tester le processus sans transférer les données volumineuses.

---

## Logs

Tous les logs (stdout + stderr) sont enregistrés dans :

```
nextcloud/logs/backup_nextcloud.log
```

Le répertoire `logs/` est créé automatiquement. Le log est également affiché dans le terminal.

---

## Lock

Un fichier de verrou est créé au démarrage pour empêcher les exécutions simultanées :

```
nextcloud/.backup_nextcloud.lock
```

Il est automatiquement supprimé à la fin du script (succès ou erreur).

---

## MQTT / Home Assistant

Quand `MQTT_ENABLED=true`, le script publie :
- Une **découverte automatique** (`homeassistant/device/backup/<id>/config`)
- Un **état JSON** après chaque backup (`backup/<id>/state`) contenant : statut, durée, timestamp, message d'erreur

---

## Cron

```cron
0 4 * * * /chemin/vers/nextcloud/backup_nextcloud.sh --backup >> /dev/null 2>&1
```

Les logs sont dans `nextcloud/logs/backup_nextcloud.log`.

---

## Dépendances

| Outil | Obligatoire |
|-------|-------------|
| `docker` | ✓ |
| `mosquitto_pub` | Si `MQTT_ENABLED=true` |
