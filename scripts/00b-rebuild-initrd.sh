#!/bin/bash
# Reconstruye kernel-cache/initrfs.img aplicando huronos-patch/livekitlib de
# nuevo, SIN recompilar el kernel (script pesado, ver 00-build-kernel.sh:
# puede tardar horas). Reutiliza el árbol de módulos ya incluido en el
# initrfs.img actual (el mismo subconjunto con NETWORK=true que
# 00-build-kernel.sh generó la última vez), así que solo hace falta volver a
# correr este script cuando el cambio sea exclusivamente a
# huronos-patch/livekitlib.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KERNEL_CACHE="${PROJECT_DIR}/kernel-cache"
BUILD_LAB="/tmp/huronos-initrd-rebuild-$$"

if [ ! -f "$KERNEL_CACHE/initrfs.img" ]; then
    echo "[ERROR] Falta kernel-cache/initrfs.img. Ejecuta primero:"
    echo "  ./scripts/00-build-kernel.sh"
    exit 1
fi

cleanup() {
    rm -rf "$BUILD_LAB"
}
trap cleanup EXIT

echo "[initrd] Extrayendo el árbol de módulos del initrfs.img actual..."
mkdir -p "$BUILD_LAB/modules-out/lib/modules"
(cd "$BUILD_LAB/modules-out" && xz -dc "$KERNEL_CACHE/initrfs.img" | cpio -idm --no-absolute-filenames 'lib/modules/*' 2>/dev/null)

if [ ! -d "$BUILD_LAB/modules-out/lib/modules/6.0.15-huronos+" ]; then
    echo "[ERROR] No se pudo extraer lib/modules/6.0.15-huronos+ del initrfs.img actual."
    exit 1
fi

echo "[initrd] Clonando huronOS-build-tools (solo para el tooling de initramfs)..."
git clone --depth 1 https://github.com/equetzal/huronOS-build-tools.git "$BUILD_LAB/build-tools"

echo "[initrd] Aplicando parche de netboot a lib/livekitlib..."
cp "$PROJECT_DIR/huronos-patch/livekitlib" "$BUILD_LAB/build-tools/base-system/livekitlib"

echo "[initrd] Generando initrfs.img con NETWORK=true (drivers de red incluidos)..."
sed -i 's/export NETWORK=false/export NETWORK=true/' "$BUILD_LAB/build-tools/base-system/config"

mkdir -p "$BUILD_LAB/initrd-out"
docker run --rm \
    -v "$BUILD_LAB/modules-out/lib/modules/6.0.15-huronos+:/lib/modules/6.0.15-huronos+:ro" \
    -v "$BUILD_LAB/build-tools/base-system:/work/base-system" \
    -v "$BUILD_LAB/initrd-out:/out" \
    -w /work/base-system \
    debian:bullseye \
    bash -c '
        set -e
        apt-get update -qq
        apt-get install -y --no-install-recommends xz-utils cpio kmod findutils procps >/dev/null 2>&1
        export HBT_LAB=/out/build-lab
        . ./config
        export HBT_LAB=/out/build-lab
        . ./livekitlib
        cd initramfs
        IMG=$(./initramfs_create)
        cp "$IMG" /out/initrfs.img
    '

cp "$BUILD_LAB/initrd-out/initrfs.img" "$KERNEL_CACHE/initrfs.img"

echo ""
echo "[OK] kernel-cache/initrfs.img regenerado con el huronos-patch/livekitlib actual."
