#!/bin/bash
# Empaqueta huronos-patch/hnetsync/ (script hnetsync-push + unidades systemd +
# drop-ins sobre hsync.service/happly.service, que suben event/contest al
# master) en una capa .hsl aditiva, mismo patrón que 02c-build-hmm-layer.sh:
# union_append_modules() recorre huronOS/base/*.hsl en orden alfabético, así
# que "07-" se monta por encima de "01-core.hsl" sin tocar ningún archivo
# original de HuronOS.
#
# La restauración (pull) NO vive aquí: corre en el initrd, dentro de
# persistent_changes() (huronos-patch/livekitlib) -- ver el comentario ahí
# sobre la ventana de 60s de system_has_just_booted().
#
# Solo hay que re-ejecutar este script si cambia huronos-patch/hnetsync/.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
HNETSYNC_PATCH="${PROJECT_DIR}/huronos-patch/hnetsync"
KERNEL_CACHE="${PROJECT_DIR}/kernel-cache"
STAGE_DIR="/tmp/huronos-hnetsync-layer-stage-$$"

if [ ! -d "$HNETSYNC_PATCH" ]; then
    echo "[ERROR] No se encontró $HNETSYNC_PATCH"
    exit 1
fi

if ! command -v mksquashfs &>/dev/null; then
    echo "[ERROR] mksquashfs no está instalado. Instala squashfs-tools."
    exit 1
fi

echo "[hnetsync-layer] Preparando staging con scripts y unidades systemd..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -a "$HNETSYNC_PATCH"/. "$STAGE_DIR"/
chmod 755 "$STAGE_DIR/usr/local/sbin/hnetsync-push"

echo "[hnetsync-layer] Generando kernel-cache/07-hnetsync.hsl..."
mkdir -p "$KERNEL_CACHE"
rm -f "$KERNEL_CACHE/07-hnetsync.hsl"
mksquashfs "$STAGE_DIR" "$KERNEL_CACHE/07-hnetsync.hsl" -comp xz

rm -rf "$STAGE_DIR"

echo ""
echo "[OK] kernel-cache/07-hnetsync.hsl listo."
