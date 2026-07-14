#!/bin/bash
# Instala las dependencias del sistema (apt) para este proyecto: tanto para la
# simulación QEMU (README.md) como para el master de hardware real
# (experimento_hardware_real/LABORATORIO-REAL.md). No compila nada pesado (el
# kernel se compila aparte con scripts/00-build-kernel.sh) ni toca la red:
# solo deja instaladas las herramientas que los demás scripts ya asumen.
#
# Por defecto autodetecta qué grupo de dependencias instalar según la
# arquitectura (x86_64 -> simulación QEMU; aarch64/armv7l -> master de
# hardware real, típico de una Raspberry Pi), pero se puede forzar con flags.
#
# Uso:
#   ./install.sh [flags]
#
# Flags:
#   --sim          Fuerza instalar dependencias de la simulación QEMU
#                  (qemu-system-x86, ipxe-qemu) aunque la arquitectura no sea x86_64.
#   --hardware     Fuerza instalar dependencias del master de hardware real
#                  (whiptail, network-manager) aunque la arquitectura no sea ARM.
#   --no-sim       No instala dependencias de simulación (aunque se autodetecten).
#   --no-hardware  No instala dependencias de hardware real (aunque se autodetecten).
#   -h, --help     Muestra esta ayuda.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WANT_SIM=""
WANT_HARDWARE=""

usage() {
    sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --sim) WANT_SIM=true; shift ;;
        --hardware) WANT_HARDWARE=true; shift ;;
        --no-sim) WANT_SIM=false; shift ;;
        --no-hardware) WANT_HARDWARE=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] Flag desconocida: $1"; usage; exit 1 ;;
    esac
done

# --- Autodetección por arquitectura si no se forzó nada ---
ARCH="$(uname -m)"
if [ -z "$WANT_SIM" ]; then
    case "$ARCH" in
        x86_64|amd64) WANT_SIM=true ;;
        *) WANT_SIM=false ;;
    esac
fi
if [ -z "$WANT_HARDWARE" ]; then
    case "$ARCH" in
        aarch64|armv7l|armv6l) WANT_HARDWARE=true ;;
        *) WANT_HARDWARE=false ;;
    esac
fi

if ! command -v apt-get &>/dev/null; then
    echo "[ERROR] Este script asume Debian/Ubuntu/Raspberry Pi OS (apt-get)."
    echo "        Instala a mano lo que pide README.md / LABORATORIO-REAL.md."
    exit 1
fi

echo "=================================================================="
echo " Instalación de dependencias -- arquitectura detectada: ${ARCH}"
echo "   Simulación QEMU:        $WANT_SIM"
echo "   Master hardware real:   $WANT_HARDWARE"
echo "=================================================================="

# --- Paquetes comunes a ambos escenarios ---
COMMON_PKGS=(docker.io docker-compose-v2 squashfs-tools kmod curl git iproute2 iptables)

# --- Simulación QEMU (README.md) ---
SIM_PKGS=(qemu-system-x86 ipxe-qemu)

# --- Master de hardware real (LABORATORIO-REAL.md) ---
HARDWARE_PKGS=(whiptail network-manager)

PKGS=("${COMMON_PKGS[@]}")
[ "$WANT_SIM" = true ] && PKGS+=("${SIM_PKGS[@]}")
[ "$WANT_HARDWARE" = true ] && PKGS+=("${HARDWARE_PKGS[@]}")

echo ""
echo "[1/3] Instalando paquetes: ${PKGS[*]}"
sudo apt-get update
sudo apt-get install -y --no-install-recommends "${PKGS[@]}"

# --- Docker: servicio activo + usuario en el grupo docker ---
echo ""
echo "[2/3] Habilitando el servicio de Docker..."
sudo systemctl enable --now docker

if ! groups "$USER" | grep -qw docker; then
    echo "        Agregando a $USER al grupo 'docker' (evita tener que usar sudo con docker)..."
    sudo usermod -aG docker "$USER"
    NEEDS_RELOGIN=true
else
    NEEDS_RELOGIN=false
fi

echo ""
echo "[3/3] Verificaciones:"
if [ "$WANT_SIM" = true ]; then
    if [ -e /dev/kvm ]; then
        echo "  KVM: /dev/kvm existe -- OK"
    else
        echo "  KVM: /dev/kvm NO existe -- la simulación QEMU será mucho más lenta (sin -enable-kvm)."
        echo "       Revisa que la virtualización esté habilitada en el BIOS/UEFI del host."
    fi
    if [ ! -f /usr/lib/ipxe/qemu/pxe-e1000.rom ]; then
        echo "  AVISO: no se encontró /usr/lib/ipxe/qemu/pxe-e1000.rom tras instalar ipxe-qemu."
        echo "         scripts/04-start-slave*.sh esperan esa ruta -- revisa el paquete en tu distro."
    fi
fi

echo ""
echo "=================================================================="
echo " Listo."
echo "=================================================================="
if [ "$NEEDS_RELOGIN" = true ]; then
    echo "  - Cierra sesión (o corre 'newgrp docker') para que el grupo 'docker' tome efecto."
fi
echo "  - Simulación QEMU: ver README.md (scripts/00-build-kernel.sh, 01-setup-network.sh, etc.)."
echo "  - Master de hardware real: ver experimento_hardware_real/LABORATORIO-REAL.md"
echo "    (experimento_hardware_real/setup-master.sh y master-tui.sh)."
