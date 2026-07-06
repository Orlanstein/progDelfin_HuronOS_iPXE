#!/bin/bash
# Limpia todo el entorno iPXE: containers, montajes, interfaces de red.
# Requiere sudo para eliminar las interfaces de red y desmontar ISO.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "[teardown] Deteniendo contenedor master..."
cd "$PROJECT_DIR"
docker compose down 2>/dev/null || true

echo "[teardown] Desmontando ISO de /mnt/huronos-iso (si quedó montada)..."
if mountpoint -q /mnt/huronos-iso; then
    umount /mnt/huronos-iso
    rmdir /mnt/huronos-iso 2>/dev/null || true
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

echo "[teardown] Eliminando reglas de NAT/forward..."
WAN_IFACE="$(ip route show default | awk '{print $5; exit}')"
if [ -n "$WAN_IFACE" ]; then
    iptables -t nat -D POSTROUTING -s 192.168.100.0/24 -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i br-ipxe -o "$WAN_IFACE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$WAN_IFACE" -o br-ipxe -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
fi

echo ""
echo "[teardown] Entorno iPXE limpiado."
