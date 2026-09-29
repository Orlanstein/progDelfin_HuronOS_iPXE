#!/bin/bash
# Corre toda la cadena de arranque que falta después de
# scripts/00-build-kernel.sh: red -> capas hmm/hnetsync (si faltan) ->
# boot/ -> directivas -> master -> verificación. Archivo nuevo -- no
# modifica ninguno de los scripts 01/02/02b/02c/02e/03, solo los invoca en
# orden (mismo comportamiento que seguir el README a mano).
#
# Pide sudo varias veces (una por cada sub-script que lo necesita), igual
# que hacerlo manualmente paso a paso.
#
# Al final quedan pendientes, en dos terminales separadas:
#   sudo ./scripts/04b-start-slave1-checked.sh
#   sudo ./scripts/04b-start-slave2-checked.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -f "$PROJECT_DIR/kernel-cache/vmlinuz-6.0.15-huronos+" ]; then
    echo "[full-boot] No se encontró kernel-cache/. Ejecuta primero (una sola vez):"
    echo "  ./scripts/00-build-kernel.sh"
    exit 1
fi

echo "[full-boot] 1/6: red virtual (br-ipxe, tap0, tap1)..."
sudo "$SCRIPT_DIR/01-setup-network.sh"

if [ ! -f "$PROJECT_DIR/kernel-cache/06-netboot-hmm.hsl" ]; then
    echo "[full-boot] 2/6: generando capa hmm (no existía)..."
    "$SCRIPT_DIR/02c-build-hmm-layer.sh"
else
    echo "[full-boot] 2/6: kernel-cache/06-netboot-hmm.hsl ya existe, omitiendo."
fi

if [ ! -f "$PROJECT_DIR/kernel-cache/07-hnetsync.hsl" ]; then
    echo "[full-boot] 3/6: generando capa hnetsync (no existía)..."
    "$SCRIPT_DIR/02e-build-hnetsync-layer.sh"
else
    echo "[full-boot] 3/6: kernel-cache/07-hnetsync.hsl ya existe, omitiendo."
fi

echo "[full-boot] 4/6: construyendo boot/ (kernel + initrd + huronos-system.sfs)..."
sudo "$SCRIPT_DIR/02-build-huronos-boot.sh"

echo "[full-boot] 5/6: publicando directivas y catálogo de software..."
sudo "$SCRIPT_DIR/02b-setup-directives.sh"

echo "[full-boot] 6/6: construyendo y levantando el master..."
"$SCRIPT_DIR/03-start-master.sh"

echo "[full-boot] Verificando que el master realmente esté sirviendo..."
sleep 2
"$SCRIPT_DIR/03b-verify-master.sh"

echo ""
echo "[OK] Master listo. Para las VMs esclavas, en dos terminales separadas:"
echo "  sudo ./scripts/04b-start-slave1-checked.sh"
echo "  sudo ./scripts/04b-start-slave2-checked.sh"
