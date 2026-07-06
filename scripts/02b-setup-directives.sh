#!/bin/bash
# Publica directives.hdf y el catálogo de software (.hsm) en boot/, para que
# el mecanismo nativo de HuronOS (hsync/happly, ya habilitado dentro de
# huronOS/base/01-core.hsl) los descargue por HTTP.
#
# - boot/directives.hdf: copia de directives/directives.hdf (editable por el
#   organizador del examen entre exámenes).
# - boot/software/<categoria>/<nombre>.hsm: catálogo completo extraído de la
#   ISO, como archivos sueltos (no un bundle único) para que hmm (parchado en
#   huronos-patch/hmm) pueda bajar bajo demanda solo los que las directivas
#   activas pidan, sin acercarse nunca al límite de 4 GiB de httpfs2.
# Requiere sudo (mount de la ISO).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ISO="${PROJECT_DIR}/huronOS-alpha-0.4-amd64.iso"
ISO_MOUNT="/mnt/huronos-iso"
BOOT_DIR="${PROJECT_DIR}/boot"
DIRECTIVES_SRC="${PROJECT_DIR}/directives/directives.hdf"

if [ ! -f "$DIRECTIVES_SRC" ]; then
    echo "[ERROR] No se encontró $DIRECTIVES_SRC"
    exit 1
fi

if [ ! -f "$ISO" ]; then
    echo "[ERROR] No se encontró la ISO: $ISO"
    exit 1
fi

# --- 1. Publicar directives.hdf ---
echo "[directives] Copiando directives.hdf a boot/..."
mkdir -p "$BOOT_DIR"
cp -v "$DIRECTIVES_SRC" "$BOOT_DIR/directives.hdf"

# --- 2. Montar la ISO ---
echo "[directives] Montando ISO en $ISO_MOUNT..."
mkdir -p "$ISO_MOUNT"
if ! mountpoint -q "$ISO_MOUNT"; then
    mount -o loop,ro "$ISO" "$ISO_MOUNT"
fi

# --- 3. Extraer el catálogo de software como archivos sueltos ---
echo "[directives] Copiando huronOS/software/ a boot/software/ (esto puede tardar)..."
rm -rf "$BOOT_DIR/software"
cp -a "$ISO_MOUNT/huronOS/software" "$BOOT_DIR/software"

# cp -a preserva los permisos originales de la ISO (solo root), pero nginx
# corre como www-data dentro del contenedor -- sin esto, serviría 404.
chmod -R a+rX "$BOOT_DIR/software"

# --- 4. Limpieza ---
echo "[directives] Desmontando ISO..."
umount "$ISO_MOUNT"
rmdir "$ISO_MOUNT" 2>/dev/null || true

echo ""
echo "[OK] Listos en ${BOOT_DIR}/:"
echo "  - directives.hdf"
echo "  - software/<categoria>/<nombre>.hsm ($(find "$BOOT_DIR/software" -name '*.hsm' | wc -l) módulos)"
