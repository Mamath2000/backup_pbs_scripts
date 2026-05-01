FROM --platform=linux/amd64 debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG PBS_CODENAME=trixie

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    update-ca-certificates; \
    \
    # Proxmox only publishes proxmox-backup-client for amd64 on trixie.
    # Force amd64 here so the image can still be built on arm64 hosts via emulation.
    mkdir -p /usr/share/keyrings; \
    curl -fsSL "https://enterprise.proxmox.com/debian/proxmox-release-${PBS_CODENAME}.gpg" -o /usr/share/keyrings/proxmox-release.gpg; \
    \
    # HTTP avoids the certificate mismatch currently served on download.proxmox.com.
    echo "deb [signed-by=/usr/share/keyrings/proxmox-release.gpg] http://download.proxmox.com/debian/pbs-client ${PBS_CODENAME} main" > /etc/apt/sources.list.d/pbs-client.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends proxmox-backup-client; \
    \
    apt-get purge -y --auto-remove curl; \
    rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["proxmox-backup-client"]
CMD ["version"]
