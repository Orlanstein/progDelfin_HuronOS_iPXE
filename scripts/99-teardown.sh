#!/bin/bash
# Limpia todo el entorno iPXE: containers, NFS, montajes, interfaces de red.
# Requiere sudo para eliminar las interfaces de red y desmontar ISO.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "[teardown] Deteniendo contenedor master..."
cd "$PROJECT_DIR"
docker compose down 2>/dev/null || true

echo "[teardown] Eliminando exportación NFS..."
sed -i '\|/mnt/ubuntu-iso|d' /etc/exports 2>/dev/null || true
exportfs -ra 2>/dev/null || true

echo "[teardown] Desmontando ISO de /mnt/ubuntu-iso..."
if mountpoint -q /mnt/ubuntu-iso; then
    umount /mnt/ubuntu-iso
    rmdir /mnt/ubuntu-iso 2>/dev/null || true
    echo "[teardown] ISO desmontada."
fi

echo "[teardown] Eliminando interfaces TAP..."
for i in 0 1; do
    if ip link show "tap${i}" &>/dev/null; then
        ip link set "tap${i}" down
        ip tuntap del "tap${i}" mode tap
        echo "[teardown] tap${i} eliminada"
    fi
done

echo "[teardown] Eliminando bridge br-ipxe..."
if ip link show br-ipxe &>/dev/null; then
    ip link set br-ipxe down
    ip link delete br-ipxe type bridge
    echo "[teardown] br-ipxe eliminado"
fi

echo ""
echo "[teardown] Entorno iPXE limpiado."
