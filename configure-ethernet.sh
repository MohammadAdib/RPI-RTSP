#!/bin/bash
#
# Configure static IP address on Raspberry Pi ethernet port
# Usage: bash configure-ethernet.sh <ip_address> [subnet_prefix]
# Example: bash configure-ethernet.sh 10.0.0.5
# Example: bash configure-ethernet.sh 10.0.0.5 24
#

set -e

if [ -z "$1" ]; then
    echo "Usage: bash configure-ethernet.sh <ip_address> [subnet_prefix]"
    echo "Example: bash configure-ethernet.sh 10.0.0.5        (defaults to /16)"
    echo "Example: bash configure-ethernet.sh 10.0.0.5 24     (/24 = 255.255.255.0)"
    echo "Example: bash configure-ethernet.sh 10.0.0.5 8      (/8  = 255.0.0.0)"
    exit 1
fi

IP_ADDRESS="$1"
SUBNET_PREFIX="${2:-16}"

# Validate IP address format
if ! [[ "$IP_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid IP address format: $IP_ADDRESS"
    exit 1
fi

# Validate subnet prefix
if ! [[ "$SUBNET_PREFIX" =~ ^[0-9]+$ ]] || [ "$SUBNET_PREFIX" -lt 1 ] || [ "$SUBNET_PREFIX" -gt 32 ]; then
    echo "ERROR: Invalid subnet prefix: /$SUBNET_PREFIX (must be 1-32)"
    exit 1
fi

# Calculate subnet mask from prefix length
calculate_subnet_mask() {
    local prefix=$1
    local mask=$((0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF))
    printf "%d.%d.%d.%d" $(( (mask >> 24) & 255 )) $(( (mask >> 16) & 255 )) $(( (mask >> 8) & 255 )) $(( mask & 255 ))
}

# Calculate gateway (first usable IP in the subnet)
calculate_gateway() {
    local ip=$1
    local prefix=$2
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    local ip_int=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    local mask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))
    local network=$(( ip_int & mask ))
    local gw=$(( network + 1 ))
    printf "%d.%d.%d.%d" $(( (gw >> 24) & 255 )) $(( (gw >> 16) & 255 )) $(( (gw >> 8) & 255 )) $(( gw & 255 ))
}

SUBNET_MASK=$(calculate_subnet_mask "$SUBNET_PREFIX")
GATEWAY=$(calculate_gateway "$IP_ADDRESS" "$SUBNET_PREFIX")
DNS="8.8.8.8"

echo "=========================================="
echo "Ethernet Static IP Configuration"
echo "=========================================="
echo "IP Address:  $IP_ADDRESS"
echo "Subnet Mask: $SUBNET_MASK (/$SUBNET_PREFIX)"
echo "Gateway:     $GATEWAY"
echo "DNS:         $DNS"
echo "=========================================="

# Find ethernet interface (usually eth0 or end0)
ETH_INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^eth|^end|^enp' | head -n1)

if [ -z "$ETH_INTERFACE" ]; then
    echo "ERROR: No ethernet interface found"
    exit 1
fi

echo "Ethernet interface: $ETH_INTERFACE"
echo ""

# Check if NetworkManager is available
if command -v nmcli &> /dev/null; then
    echo "Configuring via NetworkManager..."

    # Get connection name for the ethernet interface
    CONN_NAME=$(nmcli -t -f NAME,DEVICE con show | grep ":${ETH_INTERFACE}$" | cut -d: -f1)

    if [ -z "$CONN_NAME" ]; then
        # Create new connection if none exists
        CONN_NAME="Wired connection 1"
        nmcli con add type ethernet con-name "$CONN_NAME" ifname "$ETH_INTERFACE"
    fi

    # Configure static IP
    sudo nmcli con mod "$CONN_NAME" ipv4.addresses "${IP_ADDRESS}/${SUBNET_PREFIX}"
    sudo nmcli con mod "$CONN_NAME" ipv4.gateway "$GATEWAY"
    sudo nmcli con mod "$CONN_NAME" ipv4.dns "$DNS"
    sudo nmcli con mod "$CONN_NAME" ipv4.method manual

    # Set route metric for ethernet (higher = lower priority)
    sudo nmcli con mod "$CONN_NAME" ipv4.route-metric 600
    echo "Ethernet route metric set to 600 (lower priority)"

    # Find and configure WiFi connection (lower metric = higher priority)
    WIFI_CONN=$(nmcli -t -f NAME,TYPE con show | grep ":.*wireless" | cut -d: -f1 | head -n1)
    if [ -n "$WIFI_CONN" ]; then
        echo "Found WiFi connection: $WIFI_CONN"
        sudo nmcli con mod "$WIFI_CONN" ipv4.route-metric 200
        echo "WiFi route metric set to 200 (higher priority for internet)"
    else
        echo "No WiFi connection found, skipping WiFi priority configuration"
    fi

    echo ""
    echo "Restarting connections..."

    # Restart ethernet connection
    sudo nmcli con down "$CONN_NAME" 2>/dev/null || true
    sudo nmcli con up "$CONN_NAME"

    # Restart WiFi connection if it exists
    if [ -n "$WIFI_CONN" ]; then
        sudo nmcli con down "$WIFI_CONN" 2>/dev/null || true
        sudo nmcli con up "$WIFI_CONN" 2>/dev/null || true
    fi

    echo ""
    echo "Configuration applied via NetworkManager"
    echo "WiFi will be used for internet access (metric 200)"
    echo "Ethernet will be used for local network/streaming (metric 600)"

# Fallback to dhcpcd if NetworkManager not available
elif [ -f /etc/dhcpcd.conf ]; then
    echo "Configuring via dhcpcd..."

    # Remove any existing static config for this interface
    sudo sed -i "/^interface ${ETH_INTERFACE}/,/^interface\|^$/d" /etc/dhcpcd.conf

    # Add new static configuration
    sudo tee -a /etc/dhcpcd.conf > /dev/null << EOF

interface ${ETH_INTERFACE}
static ip_address=${IP_ADDRESS}/${SUBNET_PREFIX}
static routers=${GATEWAY}
static domain_name_servers=${DNS}
EOF

    echo ""
    echo "Configuration added to /etc/dhcpcd.conf"
    echo "Restarting dhcpcd..."
    sudo systemctl restart dhcpcd

else
    echo "ERROR: Neither NetworkManager nor dhcpcd found"
    exit 1
fi

echo ""
echo "=========================================="
echo "Configuration complete!"
echo "=========================================="
echo ""
echo "Verify with: ip addr show $ETH_INTERFACE"
echo ""
