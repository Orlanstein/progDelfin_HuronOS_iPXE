#!/bin/bash
# Arranca la VM esclava 2 via iPXE sobre tap1.
# Requiere sudo (para acceder a la interfaz TAP).
set -e

IPXE_ROM="/usr/lib/ipxe/qemu/pxe-e1000.rom"

if [ ! -f "$IPXE_ROM" ]; then
    echo "[ERROR] ROM iPXE no encontrada: $IPXE_ROM"
    echo "  Instala: sudo apt install ipxe-qemu"
    exit 1
fi

if ! ip link show tap1 &>/dev/null; then
    echo "[ERROR] Interface tap1 no existe. Ejecuta primero:"
    echo "  sudo ./scripts/01-setup-network.sh"
    exit 1
fi

echo "[slave2] Iniciando VM esclava 2 (tap1, 4 GB RAM, SDL)..."

qemu-system-x86_64 \
    -name "slave2" \
    -enable-kvm \
    -cpu host \
    -m 4096 \
    -smp 2 \
    -netdev tap,id=net0,ifname=tap1,script=no,downscript=no \
    -device e1000,netdev=net0,romfile="${IPXE_ROM}" \
    -boot order=n \
    -display sdl,gl=off,window-close=on \
    -vga std \
    -serial stdio \
    -no-reboot
