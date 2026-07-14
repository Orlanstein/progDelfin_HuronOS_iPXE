#!/bin/bash
set -e

# En hardware real (network_mode: host sobre la interfaz física del master en
# vez del bridge br-ipxe de la simulación), NetworkManager puede tardar unos
# segundos en terminar de traer la interfaz tras un reboot/reinicio del
# contenedor -- si dnsmasq arranca en ese instante, falla con "unknown
# interface" y wait -n de abajo tira todo el contenedor (incluido nginx, que
# sí estaba bien). Se espera a que la interfaz configurada en dnsmasq.conf
# tenga IP antes de lanzar nada.
IFACE="$(grep -oP '^interface=\K.*' /etc/dnsmasq.conf)"
echo "[master] Esperando a que la interfaz ${IFACE} esté lista..."
for i in $(seq 1 30); do
    ip addr show "$IFACE" 2>/dev/null | grep -q "inet " && break
    [ "$i" -eq 30 ] && echo "[master] ${IFACE} no quedó lista tras 30s, arrancando de todos modos..."
    sleep 1
done

echo "[master] Iniciando nginx..."
nginx -g "daemon off;" &
NGINX_PID=$!

echo "[master] Iniciando dnsmasq..."
dnsmasq --no-daemon --log-queries &
DNSMASQ_PID=$!

echo "[master] Iniciando sync-server (persistencia event/contest)..."
python3 /usr/local/sbin/sync-server.py &
SYNC_PID=$!

echo "[master] Master listo — DHCP + HTTP activos en ${IFACE}"

# Esperar a que alguno muera
wait -n $NGINX_PID $DNSMASQ_PID $SYNC_PID
echo "[master] Un proceso terminó inesperadamente. Saliendo."
exit 1
