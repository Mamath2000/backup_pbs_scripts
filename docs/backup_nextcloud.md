---
id: backup_nextcloud
title: backup_nextcloud.sh
---

## nextcloud/backup_nextcloud.sh

Ce script permet de réaliser des sauvegardes avancées de Nextcloud AIO, avec envoi vers Proxmox Backup Server (PBS), sauvegarde locale, export de la configuration, et publication de métriques vers Home Assistant via MQTT.

## Fonctionnalités principales

- Sauvegarde de la base PostgreSQL Nextcloud (via Docker)
- Export du fichier de configuration `config.php` (volume Docker)
- Dump du répertoire parent Nextcloud AIO
- Sauvegarde locale avec gestion de la rétention (nombre et durée)
- Envoi distant vers PBS (via Docker)
- Publication de métriques et état vers MQTT/Home Assistant
- Gestion d'erreurs robuste et logs détaillés
- Nettoyage automatique des anciens dumps et exports
- Mode test avec génération de fichiers dummy

## Utilisation

```bash
# Afficher l'aide (mode par défaut sans argument)
./backup_nextcloud.sh
./backup_nextcloud.sh --help

# Sauvegarde normale
./backup_nextcloud.sh --backup

# Vérifier uniquement la connexion PBS
./backup_nextcloud.sh --check

# Mode test avec fichiers dummy
./backup_nextcloud.sh --dummy-run
```

Le script doit être lancé depuis le dossier `nextcloud/` et nécessite un fichier de configuration `backup_nextcloud.conf` adapté.

### Options disponibles

- `--backup` : Mode normal de sauvegarde
- `--check` : Vérifie uniquement la connexion au serveur PBS (pas de sauvegarde)
- `--dummy-run` : Mode test avec fichiers dummy (valide le workflow complet sans vraie sauvegarde)
- `--help, -h` : Affiche l'aide

**Note** : Si aucune option n'est spécifiée, l'aide est affichée par défaut.

## Résumé des modes d'exécution

| Mode | Commande | Sauvegarde DB | Sauvegarde PBS | Données utilisateur | Backup-ID utilisé | Utilisation |
| ---- | -------- | ------------- | -------------- | ------------------- | ----------------- | ----------- |
| **Backup** | `--backup` | ✓ Vraie sauvegarde | ✓ Complète | ✓ Incluses | `PBS_BACKUP_ID` | Production |
| **Check** | `--check` | ✗ Aucune | ✗ Test connexion uniquement | ✗ Non sauvegardées | N/A | Validation config |
| **Dummy-run** | `--dummy-run` | ✓ Fichier dummy (50MB) | ✓ Partielle | ✗ **Exclues** | `PBS_BACKUP_ID-dummy` | Tests complets |

### Notes importantes

- **Mode backup** : Sauvegarde complète pour la production, inclut la base de données, config.php, répertoire nextcloud-aio ET toutes les données utilisateur (peut représenter plusieurs centaines de GB)
- **Mode check** : Uniquement pour vérifier la connexion PBS, ne crée aucune sauvegarde
- **Mode dummy-run** :
  - Utilise un backup-id différent (`-dummy` ajouté) pour ne pas écraser les vraies sauvegardes
  - Exclut automatiquement les données utilisateur (`NEXTCLOUD_DATA_PATH`) pour éviter des transferts de plusieurs centaines de GB
  - Idéal pour tester la configuration PBS sans impact sur les données

## Configuration

Le fichier `nextcloud/backup_nextcloud.conf` doit définir au minimum :

- `DOCKER_CONTAINER_NAME` : nom du conteneur PostgreSQL Nextcloud
- `DB_USER`, `DB_NAME` : identifiants de la base
- `BACKUP_DIR` : dossier de stockage local
- `PBS_ENABLED`, `PBS_REPOSITORY`, `PBS_PASSWORD`, `PBS_FINGERPRINT`... pour l'envoi PBS
- `MQTT_ENABLED`, `MQTT_HOST`, etc. pour l'intégration MQTT (optionnel)

Variables importantes :

- `DAYS_TO_KEEP`, `MAX_LOCAL_BACKUPS` : politique de rétention
- `COMPRESSION_LEVEL` : niveau de compression gzip
- `VERIFY_BACKUP` : vérification d'intégrité
- `NEXTCLOUD_DATA_PATH` : chemin vers les données utilisateur Nextcloud (peut être très volumineux)
  - Inclus en mode `--backup` normal
  - **Automatiquement exclu** en mode `--dummy-run`

### Image Docker PBS Client

Le script utilise une image Docker personnalisée pour communiquer avec Proxmox Backup Server. Cette image est définie par la variable `PBS_DOCKER_IMAGE` dans le fichier de configuration (par défaut : `nextcloud-pbs-client:latest`).

**Construction automatique** :

Si l'image n'existe pas lors de l'exécution du script, elle sera automatiquement construite depuis le Dockerfile situé dans `nextcloud/pbs-client/`. Cette construction se fait automatiquement avant toute tentative de connexion ou de sauvegarde vers PBS.

**Construction manuelle** (optionnel) :

```bash
cd /mnt/user/docker/_scripts/backup_pbs_scripts/nextcloud/pbs-client
docker compose build
```

## Mode check (--check)

Ce mode permet de vérifier rapidement la connexion au serveur PBS sans effectuer de sauvegarde.

**Utilisation** :

```bash
./backup_nextcloud.sh --check
```

**Comportement** :

- Vérifie que PBS_ENABLED, PBS_REPOSITORY et PBS_PASSWORD sont configurés
- Construit automatiquement l'image Docker PBS si nécessaire
- Teste la connexion au serveur PBS avec `proxmox-backup-client login`
- Affiche les informations de configuration (repository, fingerprint, namespace)
- Ne crée pas de verrou de sauvegarde
- Ne nécessite pas que le conteneur Nextcloud soit en cours d'exécution
- Retourne 0 en cas de succès, 1 en cas d'échec

**Idéal pour** :

- Valider la configuration PBS après installation
- Diagnostiquer des problèmes de connexion
- Tester les credentials et le fingerprint

## Mode dummy-run (--dummy-run)

Ce mode simule une sauvegarde complète avec des fichiers de test, permettant de valider tout le workflow.

**Configuration** :

```ini
DUMMY_FILE_SIZE_MB=50
```

**Utilisation** :

```bash
./backup_nextcloud.sh --dummy-run
```

**Comportement** :

- Aucun dump réel de la base de données PostgreSQL n'est effectué
- Un fichier dummy de la taille spécifiée (`DUMMY_FILE_SIZE_MB`) est généré à la place
- Les fichiers dummy sont compressés et traités comme de vraies sauvegardes
- L'envoi vers PBS utilise un **backup-id différent** (suffixe `-dummy` ajouté) pour ne pas mélanger avec les vraies sauvegardes
  - Exemple : si `PBS_BACKUP_ID=nextcloud-aio`, le mode dummy utilisera `nextcloud-aio-dummy`
- **Les données utilisateur Nextcloud (NEXTCLOUD_DATA_PATH) ne sont PAS sauvegardées** pour éviter de transférer des centaines de GB
- Le répertoire nextcloud-aio est sauvegardé normalement (config, scripts, etc.)
- Les métriques MQTT sont publiées normalement
- Toutes les étapes de nettoyage et de vérification sont exécutées

**Idéal pour tester** :

- La connectivité vers PBS
- La configuration MQTT/Home Assistant
- Les politiques de rétention
- Les performances du système
- Le workflow complet sans impact sur la production

## Workflow recommandé

### Première installation

1. **Copier et adapter la configuration** :

   ```bash
   cd /mnt/user/docker/_scripts/backup_pbs_scripts/nextcloud
   cp backup_nextcloud.conf.sample backup_nextcloud.conf
   nano backup_nextcloud.conf
   ```

2. **Tester la connexion PBS** :

   ```bash
   ./backup_nextcloud.sh --check
   ```

   Si l'image PBS n'existe pas, elle sera construite automatiquement.

3. **Lancer un test complet sans données** :

   ```bash
   ./backup_nextcloud.sh --dummy-run
   ```

   Cela teste tout le workflow avec des fichiers dummy et un backup-id séparé.

4. **Vérifier dans PBS** que le snapshot `nextcloud-aio-dummy` a été créé

5. **Lancer la première vraie sauvegarde** :

   ```bash
   ./backup_nextcloud.sh --backup
   ```

6. **Configurer le cron** pour les sauvegardes automatiques :

   ```bash
   # Exemple : tous les jours à 2h du matin
   0 2 * * * /mnt/user/docker/_scripts/backup_pbs_scripts/nextcloud/backup_nextcloud.sh --backup
   ```

### Nettoyage après tests

Supprimer les snapshots de test dans PBS :

```bash
proxmox-backup-client snapshot list --repository shell@pbs@192.168.100.8:backup --ns hosts
proxmox-backup-client snapshot forget host/nextcloud-aio-dummy/YYYY-MM-DDTHH:MM:SSZ --repository shell@pbs@192.168.100.8:backup --ns hosts
```

## Fonctionnement détaillé

1. **Vérifications préalables** : dépendances (docker, bc, mosquitto_pub), présence du conteneur, verrouillage anti-double exécution.
2. **Dump de la base PostgreSQL** (ou dummy en mode test), puis export du fichier `config.php`.
3. **Dump du répertoire parent** (optionnel, pour restauration avancée).
4. **Compression** (gzip) et calcul des ratios.
5. **Nettoyage** : suppression des sauvegardes/dumps/exports trop anciens ou trop nombreux.
6. **Envoi vers PBS** (si activé) : via docker, avec gestion des artefacts et métadonnées.
7. **Publication MQTT** : état, métriques, découverte Home Assistant.
8. **Gestion des erreurs** : logs, nettoyage, publication d'état d'échec.

## Sécurité et bonnes pratiques

- Le script crée un fichier de verrou pour éviter les exécutions concurrentes.
- Les identifiants et secrets doivent être protégés (droits 600 sur le .conf).
- Les logs sont détaillés et stockés dans le fichier défini par `LOG_FILE`.
- Les dumps et exports sont supprimés en cas d'échec ou à la fin selon la politique de rétention.

## Exemples de configuration

```ini
DOCKER_CONTAINER_NAME="nextcloud-aio-database"
DB_USER="nextcloud"
DB_NAME="nextcloud_database"
BACKUP_DIR="/mnt/user/docker/nextcloud-aio/backup/"
DAYS_TO_KEEP=10
MAX_LOCAL_BACKUPS=2
COMPRESSION_LEVEL=9
VERIFY_BACKUP=true
PBS_ENABLED=true
PBS_REPOSITORY="user@pbs@pbs.local:backup"
PBS_PASSWORD="motdepasse-tres-long"
PBS_FINGERPRINT="..."
MQTT_ENABLED=true
MQTT_HOST="192.168.1.100"
MQTT_PORT="1883"
MQTT_USER="mqttuser"
MQTT_PASSWORD="mqttpass"

# Taille des fichiers dummy pour --dummy-run (optionnel)
DUMMY_FILE_SIZE_MB=50
```

## Dépendances

- `docker`
- `bc`
- `mosquitto_pub` (si MQTT activé)
- Accès à PBS via docker (image proxmox-backup-server)

## Gestion des snapshots PBS

### Snapshots de test (mode dummy-run)

Les snapshots créés en mode `--dummy-run` sont identifiés par le suffixe `-dummy` :

- Production : `nextcloud-aio`
- Test : `nextcloud-aio-dummy`

Pour supprimer les snapshots de test depuis PBS :

```bash
# Lister les snapshots
proxmox-backup-client snapshot list --repository user@pbs@server:datastore

# Supprimer un snapshot dummy spécifique
proxmox-backup-client snapshot forget host/nextcloud-aio-dummy/2026-02-17T16:48:55Z --repository user@pbs@server:datastore

# Supprimer tous les snapshots dummy (attention !)
proxmox-backup-client snapshot list --repository user@pbs@server:datastore | grep "nextcloud-aio-dummy" | awk '{print $2}' | xargs -I {} proxmox-backup-client snapshot forget {} --repository user@pbs@server:datastore
```

### Monitoring des sauvegardes

Les métriques MQTT permettent de surveiller l'état des sauvegardes via Home Assistant :

- **État** : success, failed, dump_failed, compression_failed, pbs_failed
- **Durée** : temps d'exécution en secondes
- **Tailles** : fichiers compressés et ratios
- **Dernière sauvegarde** : timestamp de la dernière exécution réussie

## Auteur

Script original par Mamath2000, adapté et documenté avec GitHub Copilot.
