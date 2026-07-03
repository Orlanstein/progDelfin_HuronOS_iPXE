#!/bin/bash
# Copia el kernel/initrd de kernel-cache/ (compilados por 00-build-kernel.sh,
# con soporte de red y el parche de netboot) a boot/, y genera
# huronos-system.sfs: un bundle squashfs con lo mínimo necesario para arrancar
# (huronOS/base, huronOS/data, boot/, EFI/, checksums), que el init parcheado
# descarga por HTTP via httpfs2 (mount_data_http()) en vez de buscar un
# dispositivo de bloques físico.
#
# Deliberadamente NO se incluye huronOS/software/ (los módulos opcionales de
# IDEs/lenguajes/etc, varios GB): además de no ser necesarios para arrancar,
# el binario mount.httpfs2 de HuronOS es ELF de 32 bits y truncaba/corrompía
# los offsets al montar un .sfs de ~5 GiB (justo por encima de la barrera de
# 4 GiB), causando errores "SQUASHFS error: Unable to read fragment/page" que
# tumbaban lightdm. Manteniendo el bundle bajo 4 GiB se evita ese bug.
# Requiere sudo (mount de la ISO).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ISO="${PROJECT_DIR}/huronOS-alpha-0.4-amd64.iso"
ISO_MOUNT="/mnt/huronos-iso"
BOOT_DIR="${PROJECT_DIR}/boot"
KERNEL_CACHE="${PROJECT_DIR}/kernel-cache"
STAGE_DIR="/tmp/huronos-system-stage-$$"

if [ ! -f "$KERNEL_CACHE/vmlinuz-6.0.15-huronos+" ] || [ ! -f "$KERNEL_CACHE/initrfs.img" ]; then
    echo "[ERROR] Falta kernel-cache/. Ejecuta primero:"
    echo "  ./scripts/00-build-kernel.sh"
    exit 1
fi

if [ ! -f "$ISO" ]; then
    echo "[ERROR] No se encontró la ISO: $ISO"
    exit 1
fi

if ! command -v mksquashfs &>/dev/null; then
    echo "[ERROR] mksquashfs no está instalado. Instala squashfs-tools."
    exit 1
fi

# --- 1. Copiar kernel e initrd desde kernel-cache/ ---
echo "[build] Copiando kernel e initrd desde kernel-cache/..."
mkdir -p "$BOOT_DIR"
cp -v "$KERNEL_CACHE/vmlinuz-6.0.15-huronos+" "$BOOT_DIR/vmlinuz-6.0.15-huronos+"
cp -v "$KERNEL_CACHE/initrfs.img" "$BOOT_DIR/initrfs.img"

# --- 2. Montar la ISO ---
echo "[build] Montando ISO en $ISO_MOUNT..."
mkdir -p "$ISO_MOUNT"
if ! mountpoint -q "$ISO_MOUNT"; then
    mount -o loop,ro "$ISO" "$ISO_MOUNT"
fi

# --- 3. Preparar un staging dir solo con lo necesario para arrancar ---
echo "[build] Preparando contenido mínimo (sin huronOS/software/)..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/huronOS"
cp -a "$ISO_MOUNT/boot" "$STAGE_DIR/"
cp -a "$ISO_MOUNT/EFI" "$STAGE_DIR/"
cp -a "$ISO_MOUNT/checksums" "$STAGE_DIR/"
cp -a "$ISO_MOUNT/huronOS/base" "$STAGE_DIR/huronOS/"
cp -a "$ISO_MOUNT/huronOS/data" "$STAGE_DIR/huronOS/"

# --- 4. Generar el bundle del sistema para HTTP netboot ---
echo "[build] Generando boot/huronos-system.sfs (esto puede tardar)..."
rm -f "$BOOT_DIR/huronos-system.sfs"
mksquashfs "$STAGE_DIR" "$BOOT_DIR/huronos-system.sfs" \
    -comp xz -b 1024K -always-use-fragments

SFS_SIZE_BYTES="$(stat -c %s "$BOOT_DIR/huronos-system.sfs")"
if [ "$SFS_SIZE_BYTES" -ge 4294967296 ]; then
    echo "[AVISO] huronos-system.sfs pesa $SFS_SIZE_BYTES bytes, por encima de 4 GiB."
    echo "        httpfs2 (32 bits) puede corromper lecturas cerca del final del archivo."
fi

# --- 5. Limpieza ---
echo "[build] Desmontando ISO..."
umount "$ISO_MOUNT"
rmdir "$ISO_MOUNT" 2>/dev/null || true
rm -rf "$STAGE_DIR"

echo ""
echo "[OK] Listos en ${BOOT_DIR}/:"
echo "  - vmlinuz-6.0.15-huronos+"
echo "  - initrfs.img (con drivers de red + parche netboot)"
echo "  - huronos-system.sfs"
