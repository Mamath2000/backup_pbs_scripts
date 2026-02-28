---
id: backup_elkarbackup
title: backup_elkarbackup.sh
---

## elkarbackup/backup_elkarbackup.sh

Ce script permet de réaliser des sauvegardes avancées de la base de données MariaDB utilisée par ElkarBackup avec envoi vers Proxmox Backup Server (PBS), et sauvegarde du répertoire applicatif complet, ainsi que la publication de métriques vers Home Assistant via MQTT.

## Fonctionnalités principales

- Sauvegarde de la base de données MariaDB ElkarBackup (via Docker)
- Sauvegarde du répertoire applicatif complet (configuration, données, logs) via rsync
- Sauvegarde locale avec gestion de la rétention (nombre et durée)
- Envoi distant vers PBS avec compression éfficace
- Publication de métriques et état vers MQTT/Home Assistant
- Gestion d'erreurs robuste et logs détaillés
- Programme de nettoyage automatique des anciennes sauvegardes
- Mode test avec génération de fichiers dummy
- Mode vérification de connexion PBS

## Utilisation

```bash
# Afficher l'aide (mode par défaut sans argument)
./backup_elkarbackup.sh
./backup_elkarbackup.sh --help

# Sauvegarde normale
./backup_elkarbackup.sh --backup

# Vérifier uniquement la connexion PBS
./backup_elkarbackup.sh --check

# Mode test avec fichiers dummy
./backup_elkarbackup.sh --dummy-run
```

Le script doit être lancé depuis le dossier `elkarbackup/` et nécessite un fichier de configuration `backup_elkarbackup.conf` adapté.

### Options disponibles

- `--backup` : Mode normal de sauvegarde
- `--check` : Vérifie uniquement la connexion au serveur PBS (pas de sauvegarde)
- `--dummy-run` : Mode test avec fichiers dummy (valide le workflow complet sans vraie sauvegarde)
- `--help, -h` : Affiche l'aide

**Note** : Si aucune option n'est spécifiée, l'aide est affichée par défaut.

## Résumé des modes d'exécution

| Mode | Commande | Sauvegarde DB | Sauvegarde répertoire | Envoi PBS | Backup-ID utilisé | Utilisation |
| ---- | -------- | ------------- | ---------------------- | --------- | ----------------- | ----------- |
| **Backup** | `--backup` | ✓ Vraie sauvegarde | ✓ Copie complète (rsync) | ✓ Complète | `PBS_BACKUP_ID` | Production |
| **Check** | `--check` | ✗ Aucune | ✗ Aucune | ✗ Test connexion uniquement | N/A | Validation config |
| **Dummy-run** | `--dummy-run` | ✓ Fichier dummy (50MB) | ✓ Copie complète (rsync) | ✓ Partielle | `PBS_BACKUP_ID-dummy` | Tests complets |

### Notes importantes

- **Mode backup** : Sauvegarde complète pour la production
  - Base de données MariaDB du conteneur
  - Répertoire complet défini par `BACKUP_SOURCE_DIR` (excluant `backup/`)
  - Envoi de tous les artefacts vers PBS avec compression
  
- **Mode check** : Uniquement pour vérifier la connexion PBS, ne crée aucune sauvegarde
  
- **Mode dummy-run** :
  - Utilise un backup-id différent (`-dummy` ajouté) pour ne pas écraser les vraies sauvegardes
  - Crée un fichier dummy SQL au lieu de vrai dump MariaDB
  - Copie le répertoire complet via rsync (même que le mode réel)
  - Idéal pour tester la configuration PBS sans impact sur les données

## Configuration

Le fichier `elkarbackup/backup_elkarbackup.conf` doit définir au minimum :

### Configuration base de données

- `DOCKER_CONTAINER_NAME` : nom du conteneur MariaDB
- `DB_USER` : utilisateur pour se connecter à mariadb
- `DB_PASSWORD` : mot de passe de l'utilisateur
- `DB_NAMES` : liste des bases à sauvegarder (exemple : `("elkarbackup")`)

### Configuration sauvegardes locales

- `BACKUP_SOURCE_DIR` : répertoire source à sauvegarder (exemple : `/mnt/user/docker/elkar-v2`)
- `BACKUP_DIR` : dossier de stockage local des dumps SQL (exemple : `/mnt/user/docker/elkar-v2/backup/`)
- `DAYS_TO_KEEP` : nombre de jours de conservation (par défaut : 10)
- `MAX_LOCAL_BACKUPS` : nombre maximum de sauvegardes à conserver localement (par défaut : 5)
- `FILE_SUFFIX` : suffixe des fichiers de sauvegarde SQL (par défaut : `_elkar_backup.sql`)
- `VERIFY_BACKUP` : vérifier l'intégrité de la sauvegarde SQL (par défaut : true)

# Vérification des dumps SQL
- La vérification des dumps SQL est effectuée systématiquement par le script (paramètre `VERIFY_BACKUP` supprimé).

### Configuration PBS (Proxmox Backup Server)

- Envoi vers PBS : actif par défaut. Le paramètre `PBS_ENABLED` a été supprimé — l'envoi vers PBS est pris en charge systématiquement par le script.
- `PBS_REPOSITORY` : adresse du dépôt PBS (format : `user@realm@host` — le datastore est choisi via `PBS_DATASTORE_DEFAULT` ou l'option `--datastore`)
- `PBS_PASSWORD` : mot de passe ou token secret du serveur PBS
- `PBS_FINGERPRINT` : empreinte du certificat SSL du serveur PBS (optionnel mais recommandé)
- `PBS_BACKUP_ID` : identifiant unique pour le backup côté PBS (par défaut : `elkarbackup`)
- `PBS_BACKUP_TYPE` : supprimé (fixé à `host` dans les scripts)
- `PBS_NAMESPACE` : namespace PBS (optionnel)
- `PBS_ARCHIVE_NAME` : nom de l'archive dans le snapshot (par défaut : `elkarbackup.pxar`)
- `PBS_DOCKER_IMAGE` : image Docker pour le client PBS (par défaut : `elkarbackup-pbs-client:latest`)

Remarques sur la compression : pour les envois vers PBS, il ne faut pas compresser localement les dumps — PBS gère la compression et le dédoublonnage. La variable `COMPRESSION_LEVEL` peut rester pour des usages locaux mais est ignorée pour l'envoi vers PBS.

Changements récents (matin) :

- Docker PBS client unifié : le dépôt fournit maintenant un répertoire `pbs_client/` à la racine. Les scripts utilisent cette image centralisée et appellent automatiquement `pbs_client/build_pbs_client.sh` pour construire l'image si elle est absente. Vous pouvez toujours personnaliser `PBS_DOCKER_IMAGE` dans la configuration.
- Logs : le comportement de logging a été harmonisé — chaque script utilise la variable `LOG_FILE` définie dans sa configuration. Le script CLI crée par défaut un répertoire `logs/` à côté du script et nomme le fichier `backup_<sanitized-backup-name>.log`. Les chemins sont modifiables via `LOG_FILE` dans les fichiers de conf.
- Datastore en ligne de commande : l'option `--datastore` permet désormais de choisir le datastore cible depuis la ligne de commande. Si vous ne fournissez rien, `PBS_DATASTORE_DEFAULT` (défini dans le fichier de conf) est utilisé. `PBS_REPOSITORY` doit contenir uniquement l'hôte/compte, le datastore est concaténé par le script en `PBS_REPOSITORY_FULL`.

### Configuration MQTT (optionnel)

- `MQTT_ENABLED` : activer les notifications MQTT (true/false)
- `MQTT_HOST` : adresse du broker MQTT
- `MQTT_PORT` : port du broker (par défaut : 1883)
- `MQTT_USER` : utilisateur MQTT (optionnel)
- `MQTT_PASSWORD` : mot de passe MQTT (optionnel)
- `MQTT_STATE_TOPIC` : topic pour l'état des sauvegardes
- `MQTT_DEVICE_TOPIC` : topic pour la configuration du device

### Configuration logging

- `LOG_FILE` : chemin du fichier log (par défaut : `/var/log/mariadb_backup.log`)
- `LOG_LEVEL` : niveau de logging (DEBUG, INFO, WARN, ERROR)

## Contenu de la sauvegarde

Lors d'une sauvegarde, le script crée les artefacts suivants :

### 1. Dump SQL de la base de données

- Fichier : `YYYYMMDDHHMM_elkarbackup_elkar_backup.sql`
- Contenu : Dump complet de la base de données MariaDB
- Stockage local : `BACKUP_DIR` avec conservation limitée à `MAX_LOCAL_BACKUPS`
- Envoi PBS : Oui (avec compression PBS)

### 2. Copie du répertoire source

- Source : `BACKUP_SOURCE_DIR` (défini dans la config)
- Exclusions : Répertoire `backup/` pour éviter les doublons
- Méthode : `rsync` avec synchronisation complète
- Stockage local : Temporaire dans staging_dir pendant l'envoi PBS
- Envoi PBS : Oui (en tant que pxar compressé par PBS)

### 3. Métadonnées

- Fichier : `metadata.json`
- Contenu : Informations sur la sauvegarde (date, bases, répertoire source, fichiers inclus)
- Stockage PBS : Oui

### Flux de traitement

```
1. Dump SQL → /staging_dir/YYYYMMDDHHMM_elkarbackup_elkar_backup.sql
2. Copie rsync → /staging_dir/elkar-v2/*
3. Métadonnées → /staging_dir/metadata.json
4. PBS archive (pxar) ← stage_dir/*
5. Nettoyage local → Suppression des backups > MAX_LOCAL_BACKUPS
```

## Logs

Les scripts écrivent leurs logs dans le fichier défini par `LOG_FILE` lorsque celui-ci est configuré. Pour la plupart des scripts récents, le comportement par défaut est d'écrire dans un répertoire `logs/` placé à côté du script :

- CLI : `logs/backup_<sanitized-backup-name>.log`
- Scripts individuels : peuvent encore définir `LOG_FILE` dans leur `*.conf` si vous souhaitez un chemin personnalisé.

Dans les fichiers `*.conf.sample`, `LOG_FILE` est laissé commenté par défaut. Exemples :

```properties
# LOG_FILE="/var/log/mariadb_backup.log"  # optionnel, par défaut les scripts utilisent logs/
```

## MQTT / Home Assistant

Si activé, le script publie l'état de la sauvegarde sur un broker MQTT pour intégration dans Home Assistant.

Activation rapide (dans les fichiers `*.conf.sample`) :

```properties
# MQTT_ENABLED=false    # default: false (laissez commenté si vous n'utilisez pas MQTT)
MQTT_HOST="mqtt.example.local"  # obligatoire pour activer
# MQTT_PORT="1883"      # default: "1883"
# MQTT_USER=""          # default: empty
# MQTT_PASSWORD=""      # default: empty
```

Les métriques publiées incluent :
- État de la sauvegarde (success, failed, dump_failed, pbs_failed)
- Durée totale
- Taille des fichiers
- Timestamp du dernier backup
- Messages d'erreur en cas de problème

## Image Docker PBS Client

Le script utilise une image Docker personnalisée pour communiquer avec Proxmox Backup Server. Cette image est définie par la variable `PBS_DOCKER_IMAGE` dans le fichier de configuration (par défaut : `elkarbackup-pbs-client:latest`).

**Construction automatique** :

Si l'image n'existe pas lors de l'exécution du script, elle sera automatiquement construite depuis le Dockerfile situé dans `elkarbackup/pbs-client/`. Cette construction se fait automatiquement avant toute tentative de connexion ou de sauvegarde vers PBS.

**Construction manuelle** (optionnel) :

```bash
cd /mnt/user/docker/_scripts/backup_pbs_scripts/elkarbackup/pbs-client
docker compose build
```

## Dépendances

- `docker` : pour exécuter les conteneurs (PBS client et MariaDB)
- `rsync` : pour synchroniser le répertoire source vers le staging
- `bc` : pour les calculs de taille et statistiques
- `mosquitto-clients` : si MQTT est activé (optionnel)

## Exemple de configuration PBS

### Exemple 1 : Avec certificat auto-signé et fingerprint

```bash
PBS_ENABLED=true
PBS_REPOSITORY="shell@pbs@192.168.100.8:backup"
PBS_PASSWORD="your_very_secure_password_here_min_40_chars"
PBS_FINGERPRINT="09:68:b7:7b:e2:3e:e6:3d:4b:66:6f:16:fc:0a:54:45:a4:06:a7:f6:65:4d:47:2a:e0:e1:92:cb:db:4a:7c:ca"
PBS_BACKUP_ID="elkarbackup"
PBS_NAMESPACE="hosts"
```

### Exemple 2 : Sans fingerprint (non recommandé)

```bash
PBS_ENABLED=true
PBS_REPOSITORY="root@pam@proxy.company.local:backup"
PBS_PASSWORD="token_secret_generated_by_pbs"
PBS_BACKUP_ID="elkarbackup-prod"
```

## Obtenir le fingerprint PBS

```bash
# Obtenir le fingerprint du certificat PBS
openssl s_client -connect <pbs_host>:8007 < /dev/null | openssl x509 -noout -fingerprint -sha256
```

Exemple de sortie :
```
SHA256 Fingerprint=09:68:b7:7b:e2:3e:e6:3d:4b:66:6f:16:fc:0a:54:45:a4:06:a7:f6:65:4d:47:2a:e0:e1:92:cb:db:4a:7c:ca
```

## Cron - Exécution régulière

Exemple pour exécuter la sauvegarde chaque nuit à 2h du matin :

```cron
0 2 * * * /mnt/user/docker/_scripts/backup_pbs_scripts/elkarbackup/backup_elkarbackup.sh --backup >> /var/log/elkarbackup_cron.log 2>&1
```

## Auteur

Script créé avec l'aide de GitHub Copilot, basé sur les patterns du script backup_nextcloud.sh.
