#!/bin/bash
# Descarga y empaqueta en vendor/ (gitignored, como kernel-cache/) TODAS las
# dependencias externas de 00-build-kernel.sh, para poder reconstruir el
# kernel sin depender de que sigan vivas tal cual hoy: GitHub, kernel.org,
# SourceForge, Docker Hub y snapshot.debian.org. Ver PROGRESO.md sección 15,
# punto 1 (el kernel dejó de poder compilarse de un día para otro cuando
# bullseye salió de soporte LTS y security.debian.org retiró los paquetes en
# vivo -- este script es la prevención de que eso vuelva a pasar).
#
# Re-ejecutar este script cuando quieras refrescar el snapshot (por ejemplo,
# si cambia SNAPSHOT_DATE en 00-build-kernel.sh). No requiere sudo.
#
# Produce:
#   vendor/docker/debian-bullseye.tar   ← imagen base (docker save)
#   vendor/src/huronOS-build-tools.tar.gz
#   vendor/src/linux-6.0.15.tar.gz
#   vendor/src/aufs-standalone.tar.gz
#   vendor/src/aufs-util.tar.gz
#   vendor/debs/*.deb + Packages.gz     ← repo apt local (todos los paquetes
#                                          de PACKAGES en build-kernel.sh, más
#                                          los del paso de initrd)
#   vendor/MANIFEST.txt                 ← fechas/versiones para trazabilidad
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$PROJECT_DIR/vendor"

SNAPSHOT_DATE="$(grep -oP '^SNAPSHOT_DATE="\K[^"]+' "$SCRIPT_DIR/00-build-kernel.sh")"
if [ -z "$SNAPSHOT_DATE" ]; then
    echo "[ERROR] No se pudo leer SNAPSHOT_DATE de 00-build-kernel.sh" >&2
    exit 1
fi
echo "[vendor] Usando snapshot.debian.org/$SNAPSHOT_DATE (mismo que 00-build-kernel.sh)."

mkdir -p "$VENDOR_DIR"/src "$VENDOR_DIR"/debs "$VENDOR_DIR"/docker

# --- 1. Imagen base debian:bullseye ---
echo "[vendor] 1/4: guardando imagen debian:bullseye..."
docker pull debian:bullseye
docker save debian:bullseye -o "$VENDOR_DIR/docker/debian-bullseye.tar"

# --- 2. Repos fuente (contenido plano, sin metadata .git -- build-kernel.sh
#         nunca corre comandos git sobre ellos, solo lee/compila archivos) ---
echo "[vendor] 2/4: empaquetando repos fuente..."
vendor_repo() {
    local url="$1" ref="$2" name="$3"
    local tmp="/tmp/vendor-src-${name}-$$"
    echo "[vendor]   $name (@ ${ref:-HEAD})..."
    rm -rf "$tmp"
    if [ -n "$ref" ]; then
        git clone --depth 1 --branch "$ref" "$url" "$tmp"
    else
        # Sin --branch: mismo HEAD por defecto que usa
        # "git clone --depth 1 ..." en 00-build-kernel.sh.
        git clone --depth 1 "$url" "$tmp"
    fi
    tar -C "$tmp" --exclude=.git -czf "$VENDOR_DIR/src/${name}.tar.gz" .
    rm -rf "$tmp"
}
vendor_repo https://github.com/equetzal/huronOS-build-tools.git "" huronOS-build-tools
vendor_repo https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git v6.0.15 linux-6.0.15
vendor_repo https://github.com/sfjro/aufs-standalone aufs6.0 aufs-standalone
vendor_repo https://git.code.sf.net/p/aufs/aufs-util aufs6.0 aufs-util

# --- 3. Paquetes .deb (los de build-kernel.sh $PACKAGES + los del paso de
#         initrd en 00-build-kernel.sh) como un repo apt local ---
echo "[vendor] 3/4: descargando paquetes .deb (esto puede tardar)..."
# build-kernel.sh todavía no está extraído en el filesystem del host en este
# punto -- se saca la línea PACKAGES directo del tarball recién generado.
PKGS_LINE="$(tar -xzOf "$VENDOR_DIR/src/huronOS-build-tools.tar.gz" ./builder-scripts/kernel/build-kernel.sh | grep '^export PACKAGES=')"
if [ -z "$PKGS_LINE" ]; then
    echo "[ERROR] No se pudo extraer PACKAGES de build-kernel.sh" >&2
    exit 1
fi

DEB_CONTAINER="huronos-vendor-debs-$$"
docker run -d --name "$DEB_CONTAINER" debian:bullseye sleep 1800 >/dev/null
cleanup_deb_container() { docker rm -f "$DEB_CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup_deb_container EXIT

docker exec "$DEB_CONTAINER" bash -c "
set -e
# La imagen oficial debian:bullseye trae /etc/apt/apt.conf.d/docker-clean,
# que borra *.deb de /var/cache/apt/archives en cada DPkg::Post-Invoke (para
# no inflar layers de Docker) -- justo lo que NO queremos acá, así que se
# quita antes de tocar apt para nada.
rm -f /etc/apt/apt.conf.d/docker-clean
cat > /etc/apt/sources.list <<'SRC'
deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/${SNAPSHOT_DATE}/ bullseye main contrib non-free
deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/${SNAPSHOT_DATE}/ bullseye-updates main contrib non-free
deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/${SNAPSHOT_DATE}/ bullseye-security main contrib non-free
SRC
apt-get update -qq
$PKGS_LINE
# --download-only calcula el cierre COMPLETO de dependencias contra el
# estado del contenedor -- tiene que correr primero, con el contenedor
# todavía limpio (dpkg-dev incluido en esta misma pasada), porque instalar
# dpkg-dev de verdad ANTES marcaría paquetes base (gcc, make, xz-utils,
# libc6-dev...) como \"ya satisfechos\" por sus dependencias y los saltaría.
apt-get install -y --no-install-recommends --download-only \$PACKAGES xz-utils cpio kmod findutils procps dpkg-dev
# Instalación real (usa los .deb ya cacheados arriba, no vuelve a bajar
# nada) solo para tener el binario dpkg-scanpackages disponible.
apt-get install -y dpkg-dev
cd /var/cache/apt/archives
dpkg-scanpackages . /dev/null 2>/dev/null | gzip -9 > Packages.gz
"

docker cp "$DEB_CONTAINER:/var/cache/apt/archives/." "$VENDOR_DIR/debs/"
find "$VENDOR_DIR/debs" -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
find "$VENDOR_DIR/debs" -name '*.deb' | wc -l | xargs echo "[vendor]   .deb descargados:"

cleanup_deb_container
trap - EXIT

# --- 4. Manifiesto ---
echo "[vendor] 4/4: escribiendo MANIFEST.txt..."
{
    echo "Generado: $(date -Is)"
    echo "SNAPSHOT_DATE: $SNAPSHOT_DATE"
    echo "Paquetes .deb: $(find "$VENDOR_DIR/debs" -name '*.deb' | wc -l)"
    echo "debian:bullseye digest: $(docker image inspect debian:bullseye --format '{{index .RepoDigests 0}}' 2>/dev/null || echo 'sin digest (imagen local)')"
} > "$VENDOR_DIR/MANIFEST.txt"

echo ""
echo "[OK] vendor/ listo ($(du -sh "$VENDOR_DIR" | cut -f1)):"
find "$VENDOR_DIR" -maxdepth 2 -type f | sed 's/^/  - /'
