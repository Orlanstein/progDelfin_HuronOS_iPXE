#!/bin/bash
# Empaqueta huronos-patch/hmm (una copia de /usr/sbin/hmm con la extensión de
# fetch bajo demanda para netboot) en una capa .hsl mínima, aditiva: se monta
# por encima de huronOS/base/01-core.hsl (que trae el /usr/sbin/hmm original)
# gracias a que union_append_modules() ya recorre huronOS/base/*.hsl en orden
# alfabético — "06-" queda por encima de "01-", sin tocar ningún archivo
# original de HuronOS.
#
# Solo hay que re-ejecutar este script si cambia huronos-patch/hmm.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
HMM_PATCH="${PROJECT_DIR}/huronos-patch/hmm"
KERNEL_CACHE="${PROJECT_DIR}/kernel-cache"
STAGE_DIR="/tmp/huronos-hmm-layer-stage-$$"

if [ ! -f "$HMM_PATCH" ]; then
    echo "[ERROR] No se encontró $HMM_PATCH"
    exit 1
fi

if ! command -v mksquashfs &>/dev/null; then
    echo "[ERROR] mksquashfs no está instalado. Instala squashfs-tools."
    exit 1
fi

echo "[hmm-layer] Preparando staging con /usr/sbin/hmm parchado..."
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/usr/sbin"
cp "$HMM_PATCH" "$STAGE_DIR/usr/sbin/hmm"
chmod 755 "$STAGE_DIR/usr/sbin/hmm"

echo "[hmm-layer] Generando kernel-cache/06-netboot-hmm.hsl..."
mkdir -p "$KERNEL_CACHE"
rm -f "$KERNEL_CACHE/06-netboot-hmm.hsl"
mksquashfs "$STAGE_DIR" "$KERNEL_CACHE/06-netboot-hmm.hsl" -comp xz

rm -rf "$STAGE_DIR"

echo ""
echo "[OK] kernel-cache/06-netboot-hmm.hsl listo."
