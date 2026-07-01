#!/bin/bash
# Construye y levanta el contenedor master (DHCP + HTTP).
# No requiere sudo si el usuario está en el grupo docker.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Verificar que el bridge existe
if ! ip link show br-ipxe &>/dev/null; then
    echo "[ERROR] El bridge br-ipxe no existe. Ejecuta primero:"
    echo "  sudo ./scripts/01-setup-network.sh"
    exit 1
fi

# Verificar que los archivos de boot existen
if [ ! -f "${PROJECT_DIR}/boot/vmlinuz" ]; then
    echo "[ERROR] No se encontró boot/vmlinuz. Ejecuta primero:"
    echo "  sudo ./scripts/02-extract-iso.sh"
    exit 1
fi

echo "[master] Construyendo imagen Docker..."
cd "$PROJECT_DIR"
docker compose build

echo "[master] Iniciando contenedor master..."
docker compose up -d

echo ""
echo "[master] Contenedor corriendo. Para ver logs:"
echo "  docker logs -f ipxe-master"
echo ""
echo "[master] Verificar HTTP:"
echo "  curl http://192.168.100.1/boot.ipxe"
