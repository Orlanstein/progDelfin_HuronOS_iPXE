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

echo "[red] Habilitando salida a internet (NAT) para las VMs..."
WAN_IFACE="$(ip route show default | awk '{print $5; exit}')"
if [ -z "$WAN_IFACE" ]; then
    echo "[red] AVISO: no se detectó una interfaz con ruta default; las VMs no tendrán internet, solo red interna."
else
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    if ! iptables -t nat -C POSTROUTING -s 192.168.100.0/24 -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -o "$WAN_IFACE" -j MASQUERADE
    fi
    if ! iptables -C FORWARD -i "$BRIDGE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -i "$BRIDGE" -o "$WAN_IFACE" -j ACCEPT
    fi
    if ! iptables -C FORWARD -i "$WAN_IFACE" -o "$BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -i "$WAN_IFACE" -o "$BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi
    echo "[red] NAT $BRIDGE -> $WAN_IFACE configurado (masquerade + forward)."
fi

echo ""
echo "[red] Red lista:"
ip addr show "$BRIDGE"
echo ""
echo "  slave1 usará: tap0"
echo "  slave2 usará: tap1"
