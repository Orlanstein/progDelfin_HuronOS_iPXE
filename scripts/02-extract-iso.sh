#!/bin/bash
# Monta la ISO de Ubuntu en /mnt/ubuntu-iso y la exporta via NFS.
# Solo copia vmlinuz e initrd (ya extraídos antes si existen).
# Requiere sudo.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ISO="${PROJECT_DIR}/ubuntu-24.04.1-desktop-amd64.iso"
MOUNT_POINT="/mnt/ubuntu-iso"
BOOT_DIR="${PROJECT_DIR}/boot"
NFS_SUBNET="192.168.100.0/24"

# --- 1. Copiar kernel e initrd (si no están ya) ---
if [ ! -f "${BOOT_DIR}/vmlinuz" ] || [ ! -f "${BOOT_DIR}/initrd" ]; then
    echo "[extract] Montando ISO temporalmente para copiar kernel/initrd..."
    TMP_MOUNT="/tmp/ipxe-iso-mount"

    if mountpoint -q "$TMP_MOUNT"; then
        echo "[extract] Usando montaje existente en $TMP_MOUNT"
    else
        if [ ! -f "$ISO" ]; then
            echo "[ERROR] No se encontró la ISO: $ISO"
            exit 1
        fi
        mkdir -p "$TMP_MOUNT"
        mount -o loop,ro "$ISO" "$TMP_MOUNT"
    fi

    mkdir -p "$BOOT_DIR"
    cp -v "${TMP_MOUNT}/casper/vmlinuz" "${BOOT_DIR}/vmlinuz"
    cp -v "${TMP_MOUNT}/casper/initrd"  "${BOOT_DIR}/initrd"

    if mountpoint -q "$TMP_MOUNT"; then
        umount "$TMP_MOUNT" && rmdir "$TMP_MOUNT" 2>/dev/null || true
    fi
else
    echo "[extract] vmlinuz e initrd ya existen en boot/, omitiendo copia."
fi

# --- 2. Montar ISO en punto permanente para NFS ---
echo "[nfs] Preparando montaje NFS de la ISO en $MOUNT_POINT..."

if mountpoint -q "$MOUNT_POINT"; then
    echo "[nfs] ISO ya montada en $MOUNT_POINT."
else
    if [ ! -f "$ISO" ]; then
        echo "[ERROR] No se encontró la ISO: $ISO"
        exit 1
    fi
    mkdir -p "$MOUNT_POINT"
    mount -o loop,ro "$ISO" "$MOUNT_POINT"
    echo "[nfs] ISO montada en $MOUNT_POINT."
fi

# --- 3. Instalar NFS server si hace falta ---
if ! dpkg -s nfs-kernel-server 2>/dev/null | grep -q 'Status: install ok installed'; then
    echo "[nfs] Instalando nfs-kernel-server..."
    apt-get install -y nfs-kernel-server
else
    echo "[nfs] nfs-kernel-server ya instalado."
fi

# --- 4. Configurar exportación NFS ---
NFS_ENTRY="${MOUNT_POINT} ${NFS_SUBNET}(ro,sync,no_subtree_check,no_root_squash)"

if grep -qF "$MOUNT_POINT" /etc/exports 2>/dev/null; then
    echo "[nfs] Exportación ya existe en /etc/exports."
else
    echo "$NFS_ENTRY" >> /etc/exports
    echo "[nfs] Añadida exportación: $NFS_ENTRY"
fi

/usr/sbin/exportfs -ra
systemctl enable --now nfs-kernel-server
echo "[nfs] NFS server activo."

# --- 5. Verificar ---
echo ""
echo "[OK] ISO accesible por NFS en: 192.168.100.1:${MOUNT_POINT}"
echo "[OK] Kernel e initrd en: ${BOOT_DIR}/"
echo ""
showmount -e localhost 2>/dev/null || true
