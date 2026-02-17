# Script `backup_pbs.sh`

Ce script permet de réaliser des sauvegardes de dossiers locaux vers un serveur Proxmox Backup Server (PBS), en utilisant soit le client natif (`proxmox-backup-client` via apt), soit un conteneur Docker. Il propose également un mode de vérification de la connexion à PBS.

## Fonctionnalités principales
- Sauvegarde de plusieurs dossiers vers PBS
- Exclusion de dossiers spécifiques
- Support du client PBS via apt ou Docker
- Configuration centralisée dans un fichier `backup.conf`
- Logs détaillés
- Intégration MQTT/Home Assistant (optionnelle)
- Mode test de connexion (`--check`)

## Utilisation

### Sauvegarde
```bash
./backup_pbs.sh "nom-backup" [-d /chemin]... [-e /chemin]... [/chemin...]
```
- `nom-backup` : identifiant de la sauvegarde
- `-d /chemin` : dossier à sauvegarder (peut être répété)
- `-e /chemin` : dossier à exclure (peut être répété)
- `/chemin` : dossier à sauvegarder (sans option)

**Exemples :**
```bash
./backup_pbs.sh host-prod /etc /var/lib/app
./backup_pbs.sh host-prod -d /etc -d /var/lib/app -e /var/lib/app/cache
```

### Test de connexion
```bash
./backup_pbs.sh --check
```
Teste la connexion à PBS et affiche le résultat du test.

## Configuration
Le fichier `backup.conf` doit être présent dans le même dossier que le script. Il doit définir au minimum :
- `PBS_REPOSITORY` : URL du dépôt PBS
- `PBS_PASSWORD` ou `PBS_PASSWORD_FILE` : mot de passe ou fichier contenant le mot de passe

Variables optionnelles :
- `PBS_CLIENT_MODE` : `apt` (défaut) ou `docker`
- `PBS_DOCKER_IMAGE` : image Docker à utiliser
- `LOG_FILE` : chemin du fichier de log
- `MQTT_ENABLED`, `MQTT_HOST`, etc. pour l'intégration MQTT

## Logs
Les logs sont écrits dans le fichier défini par `LOG_FILE` (par défaut `backup.log` dans le dossier du script).

## MQTT / Home Assistant
Si activé, le script publie l'état de la sauvegarde sur un broker MQTT pour intégration dans Home Assistant.

## Dépendances
- `proxmox-backup-client` (si mode apt)
- `docker` (si mode docker)
- `mosquitto_pub` (si MQTT activé)

## Auteur
Script original par Mamath2000, modifié et documenté avec GitHub Copilot.
