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

# vendor/ (scripts/00a-vendor-dependencies.sh) es un cache local opcional con
# todo lo que este script pide a internet -- GitHub, kernel.org, SourceForge,
# Docker Hub y snapshot.debian.org. Si existe, se usa en vez de salir a la
# red (ver PROGRESO.md sección 15, punto 1: bullseye ya rompió una vez sin
# aviso). Si no existe, el comportamiento es idéntico al de siempre.
VENDOR_DIR="$PROJECT_DIR/vendor"
VENDOR_DEBS_AVAILABLE=0
[ -f "$VENDOR_DIR/debs/Packages.gz" ] && VENDOR_DEBS_AVAILABLE=1

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

if [ -f "$VENDOR_DIR/src/huronOS-build-tools.tar.gz" ]; then
    echo "[kernel] Extrayendo huronOS-build-tools desde vendor/ (sin salir a internet)..."
    mkdir -p "$BUILD_LAB"
    tar -xzf "$VENDOR_DIR/src/huronOS-build-tools.tar.gz" -C "$BUILD_LAB"
else
    echo "[kernel] Clonando huronOS-build-tools..."
    git clone --depth 1 https://github.com/equetzal/huronOS-build-tools.git "$BUILD_LAB"
fi

# Los tres repos que download_kernel() (dentro de build-kernel.sh) clona por
# su cuenta -- si ya están vendorizados, se pre-siembran acá para que esos
# "git clone ... || true" internos no encuentren directorios vacíos y no
# tengan nada que hacer (su error queda silenciado por el "|| true" de
# upstream, así que esto no rompe nada si algún tarball falta: simplemente
# ese repo puntual se clona en vivo como siempre).
KERNEL_STUFF="$BUILD_LAB/builder-scripts/kernel/kernel-stuff"
mkdir -p "$KERNEL_STUFF"
for pair in "linux-6.0.15:linux" "aufs-standalone:aufs-standalone" "aufs-util:aufs-util"; do
    vendor_name="${pair%%:*}"
    dir_name="${pair##*:}"
    if [ -f "$VENDOR_DIR/src/${vendor_name}.tar.gz" ]; then
        echo "[kernel] Pre-sembrando kernel-stuff/${dir_name} desde vendor/ (sin salir a internet)..."
        mkdir -p "$KERNEL_STUFF/${dir_name}"
        tar -xzf "$VENDOR_DIR/src/${vendor_name}.tar.gz" -C "$KERNEL_STUFF/${dir_name}"
    fi
done

if [ "$VENDOR_DEBS_AVAILABLE" -eq 1 ]; then
    echo "[kernel] Usando el repo apt local de vendor/debs/ (sin salir a internet)..."
    read -r -d '' APT_SOURCES <<EOF || true
deb [trusted=yes] file:///vendor-debs ./
EOF
else
    echo "[kernel] Fijando apt sources.list a snapshot.debian.org/$SNAPSHOT_DATE (bullseye-security ya no sirve paquetes en vivo)..."
    APT_SOURCES="$SNAPSHOT_SOURCES"
fi
echo "$APT_SOURCES" > "$BUILD_LAB/builder-scripts/kernel/sources.list"

echo "[kernel] Aplicando parche de netboot a lib/livekitlib..."
cp "$PROJECT_DIR/huronos-patch/livekitlib" "$BUILD_LAB/base-system/livekitlib"

echo "[kernel] Ajustando paralelismo del build a -j${JOBS}..."
sed -i "s/make -j 1 bzImage/make -j $JOBS bzImage/; s/make -j 1 modules/make -j $JOBS modules/" \
    "$BUILD_LAB/builder-scripts/kernel/build-kernel.sh"

if ! docker image inspect debian:bullseye >/dev/null 2>&1 && [ -f "$VENDOR_DIR/docker/debian-bullseye.tar" ]; then
    echo "[kernel] Cargando imagen debian:bullseye desde vendor/ (sin salir a Docker Hub)..."
    docker load -i "$VENDOR_DIR/docker/debian-bullseye.tar"
fi

VENDOR_DEBS_MOUNT=()
if [ "$VENDOR_DEBS_AVAILABLE" -eq 1 ]; then
    VENDOR_DEBS_MOUNT=(-v "$VENDOR_DIR/debs:/vendor-debs:ro")
fi

echo "[kernel] Compilando el kernel (esto puede tardar bastante)..."
docker run -d --name "$BUILD_CONTAINER" \
    -v "$BUILD_LAB/builder-scripts/kernel:/work" \
    "${VENDOR_DEBS_MOUNT[@]}" \
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
    -e APT_SOURCES="$APT_SOURCES" \
    -v "$BUILD_LAB/modules-out/lib/modules/6.0.15-huronos+:/lib/modules/6.0.15-huronos+:ro" \
    -v "$BUILD_LAB/base-system:/work/base-system" \
    -v "$BUILD_LAB/initrd-out:/out" \
    "${VENDOR_DEBS_MOUNT[@]}" \
    -w /work/base-system \
    debian:bullseye \
    bash -c '
        set -e
        echo "$APT_SOURCES" > /etc/apt/sources.list
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
