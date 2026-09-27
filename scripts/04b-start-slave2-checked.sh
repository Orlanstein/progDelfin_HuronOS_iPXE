#!/bin/bash
# Wrapper de 04-start-slave2.sh: mismo patrón que 04b-start-slave1-checked.sh
# (ver ahí para el porqué). No modifica 04-start-slave2.sh, lo ejecuta tal
# cual al final. Requiere sudo (igual que el original, por la interfaz TAP).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! ip link show tap1 &>/dev/null; then
    echo "[slave2-checked] Interface tap1 no existe. Ejecuta primero:"
    echo "  sudo ./scripts/01-setup-network.sh"
    exit 1
fi

echo "[slave2-checked] Verificando que el master esté sirviendo..."
if ! "$SCRIPT_DIR/03b-verify-master.sh"; then
    echo "[slave2-checked] Master no está listo (ver arriba). Abortando antes de lanzar QEMU."
    exit 1
fi

echo "[slave2-checked] Master OK, lanzando slave2..."
exec "$SCRIPT_DIR/04-start-slave2.sh"
