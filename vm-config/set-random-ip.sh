#!/usr/bin/env bash
set -euo pipefail

# Verify nmcli is installed
command -v nmcli >/dev/null || {
    echo "nmcli required" >&2
    exit 1
}

# Try up to 10 times to find a free IP
MAX_ATTEMPTS=10
ATTEMPT=1
while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    OCT2=$((RANDOM % 28 + 42))
    OCT4=$((RANDOM % 253 + 2))
    IP="192.168.${OCT2}.${OCT4}"
    GATEWAY="192.168.${OCT2}.1"

    echo "$(date -Iseconds) [Attempt $ATTEMPT/$MAX_ATTEMPTS] Checking if $IP is free..."

    if ping -c 1 -W 1 "$IP" >/dev/null 2>&1; then
        echo "IP $IP appears to be in use, trying another."
        ATTEMPT=$((ATTEMPT + 1))
    else
        echo "Selected IP $IP appears free."
        break
    fi
done

if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
    echo "Failed to find a free IP after $MAX_ATTEMPTS attempts."
    exit 2
fi

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

# --------------------------------------------
# Network robustness: verify connectivity
# --------------------------------------------
LOGFILE="/var/log/random-ip-setup.log"
{
    echo "$(date -Iseconds) Verifying connectivity after setting IP..."

    # Test connectivity to gateway
    if ping -c 2 -W 2 "${GATEWAY}" >/dev/null 2>&1; then
        echo "Gateway (${GATEWAY}) is reachable."
    else
        echo "WARNING: Gateway (${GATEWAY}) is NOT reachable."
    fi

    # Test connectivity to public DNS (Google)
    if ping -c 2 -W 2 "8.8.8.8" >/dev/null 2>&1; then
        echo "External connectivity (8.8.8.8) is working."
    else
        echo "WARNING: External connectivity (8.8.8.8) FAILED."
    fi

} | tee -a "$LOGFILE"
