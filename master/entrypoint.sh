#!/bin/bash
set -e

echo "[master] Iniciando nginx..."
nginx -g "daemon off;" &
NGINX_PID=$!

echo "[master] Iniciando dnsmasq..."
dnsmasq --no-daemon --log-queries &
DNSMASQ_PID=$!

echo "[master] Master listo — DHCP + HTTP activos en br-ipxe (192.168.100.1)"

# Esperar a que alguno muera
wait -n $NGINX_PID $DNSMASQ_PID
echo "[master] Un proceso terminó inesperadamente. Saliendo."
exit 1
