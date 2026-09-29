#!/bin/bash
# Verifica que el master (contenedor ipxe-master) esté realmente arriba y
# sirviendo, en vez de asumirlo tras "docker compose up -d" (que devuelve
# éxito aunque el contenedor entre en crash-loop después). Archivo nuevo,
# no modifica 03-start-master.sh.
#
# Uso: ./scripts/03b-verify-master.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MASTER_IP="192.168.100.1"

cd "$PROJECT_DIR"

STATUS="$(docker inspect -f '{{.State.Status}}' ipxe-master 2>/dev/null || true)"
if [ -z "$STATUS" ]; then
    echo "[verify-master] El contenedor ipxe-master no existe todavía. Ejecuta:"
    echo "  ./scripts/03-start-master.sh"
    exit 1
fi

RESTARTING="$(docker inspect -f '{{.State.Restarting}}' ipxe-master 2>/dev/null || true)"
if [ "$STATUS" != "running" ] || [ "$RESTARTING" = "true" ]; then
    echo "[verify-master] ipxe-master está en estado '$STATUS' (reiniciando: $RESTARTING), no saludable."
    echo "[verify-master] Últimas líneas de log:"
    docker logs --tail 15 ipxe-master 2>&1 | sed 's/^/    /'

    if docker logs --tail 30 ipxe-master 2>&1 | grep -q "Address already in use"; then
        echo ""
        echo "[verify-master] nginx no puede bindear el puerto 80 -- ya hay algo del HOST"
        echo "  escuchando ahí (docker-compose.yml usa network_mode: host, así que"
        echo "  compite directo con servicios del sistema, no solo con otros contenedores)."
        OFFENDER="$(systemctl list-units --type=service --state=running 2>/dev/null | grep -iE 'apache2|nginx|httpd' | awk '{print $1}' | head -1)"
        if [ -n "$OFFENDER" ]; then
            echo "  Candidato detectado: $OFFENDER está activo en este host."
            echo "  Si no lo necesitás para otra cosa:"
            echo "    sudo systemctl stop $OFFENDER"
            echo "    sudo systemctl disable $OFFENDER   # opcional, para que no vuelva a arrancar solo"
        else
            echo "  Buscá manualmente con: sudo ss -ltnp | grep ':80 '"
        fi
    fi
    exit 1
fi

echo "[verify-master] Contenedor ipxe-master: running."

FAIL=0
if ! curl -fsS --max-time 5 "http://${MASTER_IP}/boot.ipxe" >/dev/null; then
    echo "[verify-master] ERROR: http://${MASTER_IP}/boot.ipxe no responde."
    FAIL=1
fi
if ! curl -fsSI --max-time 5 "http://${MASTER_IP}/huronos-system.sfs" >/dev/null; then
    echo "[verify-master] ERROR: http://${MASTER_IP}/huronos-system.sfs no responde."
    FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
    echo "[verify-master] El contenedor corre pero HTTP no responde bien. Revisa:"
    echo "  docker logs -f ipxe-master"
    exit 1
fi

echo "[verify-master] boot.ipxe y huronos-system.sfs responden OK en ${MASTER_IP}."

if [ ! -f "$PROJECT_DIR/boot/directives.hdf" ]; then
    echo "[verify-master] AVISO: boot/directives.hdf no existe -- las VMs arrancarán con"
    echo "  el allowlist default (AllowedWebsites=all). Ejecuta si querés directivas reales:"
    echo "    sudo ./scripts/02b-setup-directives.sh"
fi
if [ ! -d "$PROJECT_DIR/boot/software" ]; then
    echo "[verify-master] AVISO: boot/software/ no existe -- AvailableSoftware no podrá"
    echo "  activarse. Ejecuta: sudo ./scripts/02b-setup-directives.sh"
fi

exit 0
