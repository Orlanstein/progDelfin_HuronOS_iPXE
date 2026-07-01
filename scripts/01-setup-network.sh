#!/bin/bash
# Crea el bridge br-ipxe y las interfaces TAP para las VMs esclavas.
# Requiere sudo.
set -e

BRIDGE="br-ipxe"
BRIDGE_IP="192.168.100.1/24"

echo "[red] Creando bridge $BRIDGE..."
if ip link show "$BRIDGE" &>/dev/null; then
    echo "[red] El bridge $BRIDGE ya existe, omitiendo."
else
    ip link add "$BRIDGE" type bridge
    ip addr add "$BRIDGE_IP" dev "$BRIDGE"
    ip link set "$BRIDGE" up
    echo "[red] Bridge $BRIDGE creado con IP $BRIDGE_IP"
fi

echo "[red] Creando interfaces TAP..."
for i in 0 1; do
    IFACE="tap${i}"
    if ip link show "$IFACE" &>/dev/null; then
        echo "[red] $IFACE ya existe, omitiendo."
    else
        ip tuntap add "$IFACE" mode tap user "$(logname 2>/dev/null || echo $SUDO_USER)"
        ip link set "$IFACE" master "$BRIDGE"
        ip link set "$IFACE" up
        echo "[red] $IFACE creado y conectado a $BRIDGE"
    fi
done

echo ""
echo "[red] Red lista:"
ip addr show "$BRIDGE"
echo ""
echo "  slave1 usará: tap0"
echo "  slave2 usará: tap1"
