#!/bin/bash
# Wrapper de 04-start-slave1.sh: corre chequeos previos (tap0 existe, el
# master realmente está sirviendo) para fallar rápido con un mensaje claro
# en vez de abrir la ventana SDL de QEMU y quedarse colgado en el PXE sin
# explicación. Archivo nuevo -- no modifica 04-start-slave1.sh, lo ejecuta
# tal cual al final (única fuente de verdad para el comando qemu).
# Requiere sudo (igual que el original, por la interfaz TAP).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! ip link show tap0 &>/dev/null; then
    echo "[slave1-checked] Interface tap0 no existe. Ejecuta primero:"
    echo "  sudo ./scripts/01-setup-network.sh"
    exit 1
fi

echo "[slave1-checked] Verificando que el master esté sirviendo..."
if ! "$SCRIPT_DIR/03b-verify-master.sh"; then
    echo "[slave1-checked] Master no está listo (ver arriba). Abortando antes de lanzar QEMU."
    exit 1
fi

echo "[slave1-checked] Master OK, lanzando slave1..."
exec "$SCRIPT_DIR/04-start-slave1.sh"
