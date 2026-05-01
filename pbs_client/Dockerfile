FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    update-ca-certificates; \
    \
    # Proxmox release key (use enterprise host for the key download; works without subscription)
    mkdir -p /usr/share/keyrings; \
    curl -fsSL "https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg" -o /usr/share/keyrings/proxmox-release.gpg; \
    \
    # PBS no-subscription repo (HTTP avoids TLS/DNS edge cases)
    echo "deb [signed-by=/usr/share/keyrings/proxmox-release.gpg] http://download.proxmox.com/debian/pbs trixie pbs-no-subscription" > /etc/apt/sources.list.d/pbs-no-subscription.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends proxmox-backup-client; \
    \
    apt-get purge -y --auto-remove curl; \
    rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["proxmox-backup-client"]
CMD ["version"]
