#!/usr/bin/env bash
set -euo pipefail

# Verify nmcli is installed
command -v nmcli >/dev/null || { echo "nmcli required" >&2; exit 1; }

# Generate random IP in 192.168.42–192.168.69
OCT2=$((RANDOM % 28 + 42))
OCT4=$((RANDOM % 253 + 2))
IP="192.168.${OCT2}.${OCT4}"
GATEWAY="192.168.${OCT2}.1"

echo "$(date -Iseconds) Setting static IP to ${IP} via ${GATEWAY}"

# Detect ethernet interface
readarray -t IFACES < <(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="ethernet"{print $1}')
IFACE=${IFACES[1]:-${IFACES[0]}}
echo "Using interface: ${IFACE}"

# Wait for interface to appear
until ip link show "${IFACE}" >/dev/null 2>&1; do
    echo "Waiting for ${IFACE}..."
    sleep 1
done

# Update or create connection named random-static
if nmcli con show random-static >/dev/null 2>&1; then
    nmcli con mod random-static ipv4.addresses "${IP}/16" ipv4.gateway "${GATEWAY}"
else
    nmcli con add type ethernet ifname "${IFACE}" con-name random-static \
    ipv4.method manual ipv4.addresses "${IP}/16" \
    ipv4.gateway "${GATEWAY}" ipv4.dns "8.8.8.8"
fi
nmcli con up random-static
nmcli con mod random-static connection.autoconnect yes
