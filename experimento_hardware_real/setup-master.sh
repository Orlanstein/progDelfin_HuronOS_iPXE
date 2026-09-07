#!/bin/bash
# Setup completo del master de hardware real (Raspberry Pi o cualquier PC) en
# la red del MikroTik hEX lite: automatiza los pasos manuales documentados en
# LABORATORIO-REAL.md (secciones 4 y 6) para que una máquina nueva quede lista
# como master con un solo comando, y para que una máquina ya provisionada se
# pueda volver a levantar con las mismas flags (ver --skip-boot-build).
#
# La IP del master (192.168.2.2/24) y el gateway (192.168.2.1, el MikroTik)
# quedan fijos: son parte del diseño de red ya armado en el MikroTik, no
# dependen de qué máquina hace de master. Lo único que sí cambia entre
# máquinas es el nombre de la interfaz Ethernet -- por eso es la única flag
# de red que existe (--iface).
#
# Uso:
#   ./setup-master.sh [flags]
#
# Flags:
#   --iface IFACE          Interfaz Ethernet hacia el MikroTik (default: eth0)
#   --configure-network     Aplica la IP estática 192.168.2.2/24 sobre --iface
#                            vía nmcli. NO es el default: es el paso más
#                            riesgoso (si --iface apunta a la interfaz
#                            equivocada, puede cortar tu propia sesión SSH).
#                            Omite esta flag si la red ya está configurada
#                            (ver sección 4 de LABORATORIO-REAL.md) o si vas
#                            a hacerlo a mano.
#   --build-kernel           Si falta kernel-cache/, corre scripts/00-build-kernel.sh
#                            primero. Tarda horas y requiere Docker + internet.
#                            Sin esta flag, el script se detiene y te avisa.
#   --skip-boot-build        No regenera boot/huronos-system.sfs ni
#                            directives.hdf/software/ (usa lo que ya esté en
#                            boot/). Útil para solo reiniciar el contenedor
#                            tras un reboot, sin re-montar la ISO de 5GB.
#   --skip-docker            No construye ni levanta el contenedor (deja
#                            boot/ y tftpboot/ listos, nada más).
#   -h, --help                Muestra esta ayuda.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

MASTER_IP="192.168.2.2"
GATEWAY_IP="192.168.2.1"
DNS_IP="8.8.8.8"
IFACE="eth0"
CONFIGURE_NETWORK=false
BUILD_KERNEL=false
SKIP_BOOT_BUILD=false
SKIP_DOCKER=false

usage() {
    sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --iface) IFACE="$2"; shift 2 ;;
        --configure-network) CONFIGURE_NETWORK=true; shift ;;
        --build-kernel) BUILD_KERNEL=true; shift ;;
        --skip-boot-build) SKIP_BOOT_BUILD=true; shift ;;
        --skip-docker) SKIP_DOCKER=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] Flag desconocida: $1"; usage; exit 1 ;;
    esac
done

echo "=================================================================="
echo " Setup del master (hardware real) -- ${MASTER_IP} sobre ${IFACE}"
echo "=================================================================="

# --- 1. Herramientas necesarias ---
echo "[1/8] Verificando herramientas..."
MISSING=""
for tool in docker mksquashfs curl; do
    command -v "$tool" &>/dev/null || MISSING="$MISSING $tool"
done
if ! docker compose version &>/dev/null; then
    MISSING="$MISSING docker-compose-plugin"
fi
if [ -n "$MISSING" ]; then
    echo "[ERROR] Falta(n):$MISSING"
    echo "        En Debian/Ubuntu/Raspberry Pi OS: sudo apt install docker.io docker-compose-v2 squashfs-tools curl"
    exit 1
fi

# --- 2. ISO de HuronOS ---
ISO="${PROJECT_DIR}/huronOS-alpha-0.4-amd64.iso"
if [ ! -f "$ISO" ]; then
    echo "[ERROR] No se encontró $ISO"
    echo "        Es un archivo de ~5GB, no viaja en git -- cópialo a mano a esa ruta"
    echo "        (scp desde otra máquina que ya lo tenga, o descárgalo de nuevo)."
    exit 1
fi
echo "[2/8] ISO de HuronOS encontrada."

# --- 3. kernel-cache/ (kernel + initrd con drivers de red) ---
if [ ! -f "$PROJECT_DIR/kernel-cache/vmlinuz-6.0.15-huronos+" ] || [ ! -f "$PROJECT_DIR/kernel-cache/initrfs.img" ]; then
    if [ "$BUILD_KERNEL" = true ]; then
        echo "[3/8] kernel-cache/ no existe, compilando (esto puede tardar horas)..."
        "$PROJECT_DIR/scripts/00-build-kernel.sh"
    else
        echo "[ERROR] Falta kernel-cache/ (vmlinuz/initrfs.img)."
        echo "        Compílalo una vez con: ./scripts/00-build-kernel.sh (horas, requiere Docker+internet)"
        echo "        o cópialo desde otra máquina que ya lo tenga, o reintenta con --build-kernel."
        exit 1
    fi
else
    echo "[3/8] kernel-cache/ ya existe, no se recompila."
fi

# --- 4. Capas aditivas hmm/hnetsync (baratas, siempre se regeneran) ---
echo "[4/8] Regenerando capas 06-netboot-hmm.hsl y 07-hnetsync.hsl..."
"$PROJECT_DIR/scripts/02c-build-hmm-layer.sh"
"$PROJECT_DIR/scripts/02e-build-hnetsync-layer.sh"

# --- 5. boot/ (bundle del sistema + directivas) ---
if [ "$SKIP_BOOT_BUILD" = true ]; then
    echo "[5/8] --skip-boot-build: se usa boot/ tal como está."
    if [ ! -f "$PROJECT_DIR/boot/huronos-system.sfs" ]; then
        echo "[ERROR] boot/huronos-system.sfs no existe y pediste --skip-boot-build. Quita la flag para generarlo."
        exit 1
    fi
else
    echo "[5/8] Generando boot/ (monta la ISO, requiere sudo)..."
    sudo "$PROJECT_DIR/scripts/02-build-huronos-boot.sh"
    sudo "$PROJECT_DIR/scripts/02b-setup-directives.sh"
fi

# --- 6. snponly.efi (chainload TFTP para firmware PXE no-iPXE) ---
SNPONLY="$SCRIPT_DIR/tftpboot/snponly.efi"
if [ ! -f "$SNPONLY" ]; then
    echo "[6/8] Descargando snponly.efi..."
    mkdir -p "$SCRIPT_DIR/tftpboot"
    curl -fSL -o "$SNPONLY" http://boot.ipxe.org/x86_64-efi/snponly.efi
else
    echo "[6/8] snponly.efi ya existe."
fi

# boot.ipxe de hardware real (server=192.168.2.2) sobreescribe el de la
# simulación QEMU en boot/ -- ver nota en LABORATORIO-REAL.md sección 6.
cp "$SCRIPT_DIR/boot.ipxe" "$PROJECT_DIR/boot/boot.ipxe"

# --- 7. Red del master (opcional, deshabilitado por defecto) ---
if [ "$CONFIGURE_NETWORK" = true ]; then
    echo "[7/8] Configurando IP estática ${MASTER_IP}/24 en ${IFACE}..."
    if ! command -v nmcli &>/dev/null; then
        echo "[ERROR] nmcli no está disponible. Configura la red a mano (ver LABORATORIO-REAL.md sección 4)."
        exit 1
    fi
    CONN="$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v d="$IFACE" '$2==d {print $1; exit}')"
    if [ -z "$CONN" ]; then
        echo "[ERROR] No hay conexión de NetworkManager asociada a ${IFACE}. Revisa 'nmcli connection show'."
        exit 1
    fi
    nmcli connection modify "$CONN" \
        ipv4.method manual \
        ipv4.addresses "${MASTER_IP}/24" \
        ipv4.gateway "$GATEWAY_IP" \
        ipv4.dns "$DNS_IP"
    nmcli connection up "$CONN"
    echo "        Verificando: $(ip -4 addr show "$IFACE" | grep -oP 'inet \K[\d.]+/\d+')"
else
    echo "[7/8] --configure-network no indicado: se asume que ${IFACE} ya tiene ${MASTER_IP}/24"
    echo "        (si no, corre este script con --configure-network o revisa LABORATORIO-REAL.md sección 4)."
fi

# --- 8. Contenedor Docker ---
if [ "$SKIP_DOCKER" = true ]; then
    echo "[8/8] --skip-docker: no se toca el contenedor."
else
    echo "[8/8] Levantando el contenedor master..."
    (cd "$SCRIPT_DIR" && docker compose build && docker compose up -d)
fi

echo ""
echo "=================================================================="
echo " Listo. Verificación rápida:"
echo "=================================================================="
if [ "$SKIP_DOCKER" = false ]; then
    docker ps --filter name=ipxe-master --format '  {{.Names}}: {{.Status}}'
    echo -n "  HTTP boot.ipxe: "
    curl -sf -o /dev/null "http://${MASTER_IP}/boot.ipxe" && echo "OK" || echo "FALLÓ (revisa docker logs -f ipxe-master)"
fi
echo ""
echo "Pendiente (no lo hace este script, son de otro equipo/lado):"
echo "  - MikroTik: confirma que su DHCP server propio (dhcp-lan) siga deshabilitado"
echo "    (/ip dhcp-server print -- ver LABORATORIO-REAL.md sección 3)."
echo "  - Arranca la laptop/PC cliente por PXE y sigue el checklist de la sección 9"
echo "    de LABORATORIO-REAL.md (DHCP, arranque completo, directivas, hnetsync)."
