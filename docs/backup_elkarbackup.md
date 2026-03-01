---
id: backup_elkarbackup
title: backup_elkarbackup.sh — Sauvegarde ElkarBackup
sidebar_label: ElkarBackup
slug: /backup-elkarbackup
---

# `elkarbackup/backup_elkarbackup.sh` — Sauvegarde ElkarBackup

Script dédié à la sauvegarde de l'instance **ElkarBackup** (application + MariaDB + backups locaux) vers Proxmox Backup Server via Docker.

---

## Ce qui est sauvegardé

| Archive PBS | Chemin source | Description |
|-------------|---------------|-------------|
| `source_safe.pxar` | `BACKUP_SOURCE_DIR` | Répertoire de l'application ElkarBackup (volumes Docker, config, etc.) |
| `backup_safe.pxar` | `BACKUP_DIR` | Répertoire des backups locaux ElkarBackup (jobs Elkar) |

**Avant l'envoi PBS**, le script effectue également :
- Un **dump SQL MariaDB** pour chaque base dans `DB_NAMES`, enregistré dans `BACKUP_DIR`.
- La génération d'un fichier `metadata.json` dans le répertoire de staging.

### Exclusions (dans `source_safe.pxar`)

| Pattern | Raison |
|---------|--------|
| `backup` | Évite de doubler le contenu de `BACKUP_DIR` |
| `mariadb/db` | Fichiers binaires MariaDB (remplacés par le dump SQL) |

---

## Étapes du backup

```
1. Vérification config       — conf, droits, dépendances
2. Lock fichier              — .backup_elkarbackup.lock dans SCRIPT_DIR
3. Dump MariaDB              — docker exec <DOCKER_CONTAINER_NAME> mariadb-dump
                               → BACKUP_DIR/YYYYMMDDHHMM_<db>_elkar_backup.sql
4. Nettoyage local           — suppression des exports anciens (DAYS_TO_KEEP / MAX_LOCAL_BACKUPS)
5. Staging dir               — création d'un répertoire temporaire avec metadata.json
6. Sauvegarde PBS            — docker run proxmox-pbs-client:latest backup
                               source_safe.pxar:/source backup_safe.pxar:/backups
7. Nettoyage staging         — suppression du répertoire temporaire
8. Notification MQTT         — si MQTT_ENABLED=true
9. Libération lock
```

---

## Configuration — `elkarbackup/backup_elkarbackup.conf`

Le fichier doit avoir les droits **600** (vérifié au démarrage).

### Variables obligatoires

| Variable | Description | Exemple |
|----------|-------------|---------|
| `PBS_REPOSITORY` | Adresse PBS **sans datastore** (`user@realm@host`) | `shell@pbs@192.168.100.8` |
| `PBS_DATASTORE_DEFAULT` | Datastore PBS cible | `ds3` |
| `PBS_PASSWORD` | Mot de passe PBS (> 40 caractères) | `…` |
| `PBS_BACKUP_ID` | Identifiant du snapshot PBS | `elkarbackup` |
| `BACKUP_SOURCE_DIR` | Répertoire racine de l'application ElkarBackup | `/mnt/user/docker/elkar-v2` |
| `BACKUP_DIR` | Répertoire contenant les backups locaux Elkar | `/mnt/user/docker/elkar-v2/backup/` |
| `DOCKER_CONTAINER_NAME` | Nom du conteneur MariaDB | `mariadb` |
| `DB_USER` | Utilisateur MariaDB | `root` |
| `DB_PASSWORD` | Mot de passe MariaDB | `…` |
| `DB_NAMES` | Tableau des bases à dumper | `("elkarbackup")` |

### Variables optionnelles

| Variable | Défaut | Description |
|----------|--------|-------------|
| `PBS_FINGERPRINT` | — | Empreinte TLS du serveur PBS |
| `PBS_NAMESPACE` | — | Namespace PBS (ex: `Hosts`) |
| `DAYS_TO_KEEP` | `10` | Durée de rétention des dumps locaux (jours) |
| `MAX_LOCAL_BACKUPS` | `2` | Nombre maximum de dumps locaux conservés |
| `COMPRESSION_LEVEL` | `0` | Compression locale (0 = aucune, PBS compresse nativement) |
| `MQTT_ENABLED` | `false` | Activer les notifications MQTT |
| `MQTT_HOST` | `localhost` | Adresse du broker MQTT |
| `MQTT_PORT` | `1883` | Port MQTT |
| `MQTT_USER` | — | Utilisateur MQTT |
| `MQTT_PASSWORD` | — | Mot de passe MQTT |
| `LOG_LEVEL` | `INFO` | Niveau de log (`DEBUG`, `INFO`, `WARNING`, `ERROR`) |

---

## Construction de `PBS_REPOSITORY_FULL`

```
PBS_REPOSITORY_FULL = PBS_REPOSITORY : DATASTORE
```

Le datastore est déterminé dans cet ordre de priorité :
1. `--datastore NAME` (CLI, si supporté ultérieurement)
2. `PBS_DATASTORE_DEFAULT` (conf)
3. `backup` (fallback)

**Exemple :**
```
PBS_REPOSITORY="shell@pbs@192.168.100.8"
PBS_DATASTORE_DEFAULT="ds3"
→ PBS_REPOSITORY_FULL="shell@pbs@192.168.100.8:ds3"
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
  [-v /chemin/vers/password_file:/pbs_password:ro] \
  [-e PBS_PASSWORD_FILE=/pbs_password] \
  -v "$BACKUP_SOURCE_DIR":/source:ro \
  -v "$BACKUP_DIR":/backups:ro \
  proxmox-pbs-client:latest \
  backup source_safe.pxar:/source backup_safe.pxar:/backups \
    --backup-id "$PBS_BACKUP_ID" \
    --backup-type host \
    [--ns "$PBS_NAMESPACE"] \
    --repository "$PBS_REPOSITORY_FULL" \
    --exclude backup --exclude mariadb/db
```

---

## Test de connexion

```bash
./backup_elkarbackup.sh --check [--datastore NAME] [--namespace NAME]
```

Exécute `proxmox-backup-client list` via Docker pour vérifier l'accès au datastore PBS. Affiche la liste des snapshots existants.

---

## Logs

Tous les logs (stdout + stderr) sont enregistrés dans :

```
elkarbackup/logs/backup_elkarbackup.log
```

Le répertoire `logs/` est créé automatiquement. Le log est également affiché dans le terminal.

---

## Lock

Un fichier de verrou est créé au démarrage pour empêcher les exécutions simultanées :

```
elkarbackup/.backup_elkarbackup.lock
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
0 3 * * * /chemin/vers/elkarbackup/backup_elkarbackup.sh >> /dev/null 2>&1
```

Les logs sont dans `elkarbackup/logs/backup_elkarbackup.log`.

---

## Dépendances

| Outil | Obligatoire |
|-------|-------------|
| `docker` | ✓ |
| `mosquitto_pub` | Si `MQTT_ENABLED=true` |
