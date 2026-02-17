---
id: backup_nextcloud
title: backup_nextcloud.sh
---
# `nextcloud/backup_nextcloud.sh`

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
./backup_nextcloud.sh
```

Le script doit être lancé depuis le dossier `nextcloud/` et nécessite un fichier de configuration `backup_nextcloud.conf` adapté.

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
```

## Dépendances
- `docker`
- `bc`
- `mosquitto_pub` (si MQTT activé)
- Accès à PBS via docker (image proxmox-backup-server)

## Auteur
Script original par Mamath2000, adapté et documenté avec GitHub Copilot.
