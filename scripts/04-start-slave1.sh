#!/bin/bash
# Arranca la VM esclava 1 via iPXE sobre tap0.
# Requiere sudo (para acceder a la interfaz TAP).
set -e

IPXE_ROM="/usr/lib/ipxe/qemu/pxe-e1000.rom"

if [ ! -f "$IPXE_ROM" ]; then
    echo "[ERROR] ROM iPXE no encontrada: $IPXE_ROM"
    echo "  Instala: sudo apt install ipxe-qemu"
    exit 1
fi

if ! ip link show tap0 &>/dev/null; then
    echo "[ERROR] Interface tap0 no existe. Ejecuta primero:"
    echo "  sudo ./scripts/01-setup-network.sh"
    exit 1
fi

echo "[slave1] Iniciando VM esclava 1 (tap0, 6 GB RAM, SDL)..."

qemu-system-x86_64 \
    -name "slave1" \
    -enable-kvm \
    -cpu host \
    -m 6144 \
    -smp 2 \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
    -device e1000,netdev=net0,mac=52:54:00:12:34:01,romfile="${IPXE_ROM}" \
    -boot order=n \
    -display sdl,gl=off,window-close=on \
    -vga std \
    -serial stdio \
    -no-reboot
