#!/bin/bash
# One-time (rarely re-run) build of the huronOS kernel. The ISO ships a kernel
# with NETWORK=false at build time (see huronOS-build-tools/base-system/config),
# which means its initrd has zero NIC drivers -- not a bug, a deliberate switch
# for USB-only boots. This script recompiles the same kernel (6.0.15 + AUFS
# patches, huronOS's own huronos.config) using huronOS's own reproducible
# builder-scripts/kernel/build-kernel.sh, then rebuilds the initrd with
# NETWORK=true (so e1000/e1000e get included) and huronos-patch/livekitlib
# applied (adds find_data_netboot(), the only local addition to HuronOS: an
# HTTP-based alternative to the physical-USB UUID search, using huronOS's own
# unused-until-now mount_data_http()/httpfs2 code).
#
# This is a REAL kernel compile (make bzImage + make modules). Expect this to
# take a long time (potentially hours) depending on available CPU. Requires
# Docker and outbound network access (clones kernel.org + AUFS repos, and
# installs ~250 build packages inside a debian:bullseye container).
#
# Output: kernel-cache/vmlinuz-6.0.15-huronos+ and kernel-cache/initrfs.img
# (gitignored -- regenerate with this script, don't hand-edit them).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_LAB="/tmp/huronos-kernel-build-$$"
JOBS="${JOBS:-$(( $(nproc) / 2 ))}"
[ "$JOBS" -lt 1 ] && JOBS=1
BUILD_CONTAINER="huronos-kernel-build-$$"

# bullseye salió de soporte LTS en 2026 y security.debian.org ya retiró los
# .deb en vivo (el índice anuncia versiones -security que ya no están en el
# pool -> 404 en cascada durante el apt install de ~250 paquetes), mientras
# que archive.debian.org todavía no re-aloja bullseye-security. Se usa un
# snapshot fijo de antes del retiro (índices y pool consistentes entre sí)
# para las tres suites, evitando además mezclar versiones "main" viejas con
# las -security ya instaladas en la imagen base debian:bullseye.
SNAPSHOT_DATE="20260901T000000Z"
read -r -d '' SNAPSHOT_SOURCES <<EOF || true
deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/$SNAPSHOT_DATE/ bullseye main contrib non-free
deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/$SNAPSHOT_DATE/ bullseye-updates main contrib non-free
deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/$SNAPSHOT_DATE/ bullseye-security main contrib non-free
EOF

cleanup() {
    status=$?
    if [ "$status" -ne 0 ] && [ -f "$BUILD_LAB/builder-scripts/kernel/build.log" ]; then
        FAILLOG="$PROJECT_DIR/kernel-cache/last-build-failure.log"
        mkdir -p "$PROJECT_DIR/kernel-cache"
        cp "$BUILD_LAB/builder-scripts/kernel/build.log" "$FAILLOG"
        echo "[kernel] Build fallido. Log de compilación guardado en: $FAILLOG" >&2
    fi
    docker rm -f "$BUILD_CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$BUILD_LAB"
}
trap cleanup EXIT

echo "[kernel] Clonando huronOS-build-tools..."
git clone --depth 1 https://github.com/equetzal/huronOS-build-tools.git "$BUILD_LAB"

echo "[kernel] Fijando apt sources.list a snapshot.debian.org/$SNAPSHOT_DATE (bullseye-security ya no sirve paquetes en vivo)..."
echo "$SNAPSHOT_SOURCES" > "$BUILD_LAB/builder-scripts/kernel/sources.list"

echo "[kernel] Aplicando parche de netboot a lib/livekitlib..."
cp "$PROJECT_DIR/huronos-patch/livekitlib" "$BUILD_LAB/base-system/livekitlib"

echo "[kernel] Ajustando paralelismo del build a -j${JOBS}..."
sed -i "s/make -j 1 bzImage/make -j $JOBS bzImage/; s/make -j 1 modules/make -j $JOBS modules/" \
    "$BUILD_LAB/builder-scripts/kernel/build-kernel.sh"

echo "[kernel] Compilando el kernel (esto puede tardar bastante)..."
docker run -d --name "$BUILD_CONTAINER" \
    -v "$BUILD_LAB/builder-scripts/kernel:/work" \
    -w /work \
    debian:bullseye \
    bash -c './build-kernel.sh --build > /work/build.log 2>&1'

# Muestra el log en vivo mientras compila (antes quedaba oculto dentro del
# contenedor hasta el final, así que un fallo a mitad de camino pasaba
# desapercibido hasta el paso de extracción de módulos). build.log vive en el
# bind mount, así que se puede tail-ear desde el host mientras el contenedor
# sigue corriendo.
while [ ! -f "$BUILD_LAB/builder-scripts/kernel/build.log" ]; do sleep 0.5; done
tail -f -n +1 "$BUILD_LAB/builder-scripts/kernel/build.log" &
TAIL_PID=$!
EXIT_CODE="$(docker wait "$BUILD_CONTAINER")"
kill "$TAIL_PID" >/dev/null 2>&1 || true

# save_kernel() (el último paso de build-kernel.sh --build) hace
# "cp /usr/lib/modules/$NAME ..." para armar un tarball de conveniencia, pero
# en este debian:bullseye sin usr-merge los módulos quedan en /lib/modules, no
# en /usr/lib/modules -- ese cp falla y hace que --build termine con código
# != 0 aunque la compilación (bzImage + modules + AUFS) haya sido exitosa. No
# tratamos esto como fatal aquí: la extracción de abajo usa la ruta correcta
# (/lib/modules) y el chequeo de "kernel/drivers/net" que sigue es la
# validación real de que el build sirvió.
if [ "$EXIT_CODE" != "0" ]; then
    echo "[kernel] Aviso: build-kernel.sh --build terminó con código $EXIT_CODE (posiblemente el cp final de save_kernel(), que usa una ruta de módulos distinta). Verificando si los artefactos reales quedaron listos igual..." >&2
fi

# save_kernel() (el último paso de build-kernel.sh --build) asume que los
# módulos quedan en /usr/lib/modules, pero en un debian:bullseye sin usr-merge
# quedan en /lib/modules -- por eso se extraen los módulos directamente del
# contenedor en vez de depender del tarball que build-kernel.sh intenta crear.
echo "[kernel] Extrayendo módulos y kernel compilados del contenedor..."
mkdir -p "$BUILD_LAB/modules-out/lib/modules" "$BUILD_LAB/modules-out/boot"
docker cp "$BUILD_CONTAINER:/lib/modules/6.0.15-huronos+" "$BUILD_LAB/modules-out/lib/modules/6.0.15-huronos+"
docker cp "$BUILD_CONTAINER:/work/kernel-stuff/linux/arch/x86/boot/bzImage" "$BUILD_LAB/modules-out/boot/vmlinuz-6.0.15-huronos+"

if [ ! -d "$BUILD_LAB/modules-out/lib/modules/6.0.15-huronos+/kernel/drivers/net" ]; then
    echo "[ERROR] La compilación no produjo módulos de red. Revisa $BUILD_LAB/builder-scripts/kernel/build.log"
    exit 1
fi

echo "[kernel] Regenerando modules.dep (depmod)..."
depmod -b "$BUILD_LAB/modules-out" 6.0.15-huronos+

echo "[kernel] Generando initrfs.img con NETWORK=true (drivers de red incluidos)..."
sed -i 's/export NETWORK=false/export NETWORK=true/' "$BUILD_LAB/base-system/config"

mkdir -p "$PROJECT_DIR/kernel-cache" "$BUILD_LAB/initrd-out"
docker run --rm \
    -e SNAPSHOT_SOURCES="$SNAPSHOT_SOURCES" \
    -v "$BUILD_LAB/modules-out/lib/modules/6.0.15-huronos+:/lib/modules/6.0.15-huronos+:ro" \
    -v "$BUILD_LAB/base-system:/work/base-system" \
    -v "$BUILD_LAB/initrd-out:/out" \
    -w /work/base-system \
    debian:bullseye \
    bash -c '
        set -e
        echo "$SNAPSHOT_SOURCES" > /etc/apt/sources.list
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

cp "$BUILD_LAB/modules-out/boot/vmlinuz-6.0.15-huronos+" "$PROJECT_DIR/kernel-cache/"
cp "$BUILD_LAB/initrd-out/initrfs.img" "$PROJECT_DIR/kernel-cache/"

echo ""
echo "[OK] kernel-cache/ listo:"
echo "  - vmlinuz-6.0.15-huronos+"
echo "  - initrfs.img (NETWORK=true + huronos-patch/livekitlib aplicado)"
