#!/bin/bash
#
# Configure static IP address on Raspberry Pi ethernet port
# Usage: bash configure-ethernet.sh <ip_address>
# Example: bash configure-ethernet.sh 10.0.0.5
#

set -e

if [ -z "$1" ]; then
    echo "Usage: bash configure-ethernet.sh <ip_address>"
    echo "Example: bash configure-ethernet.sh 10.0.0.5"
    exit 1
fi

IP_ADDRESS="$1"

# Validate IP address format
if ! [[ "$IP_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid IP address format: $IP_ADDRESS"
    exit 1
fi

# Extract first two octets for gateway calculation (assumes /16 subnet)
IFS='.' read -r OCT1 OCT2 OCT3 OCT4 <<< "$IP_ADDRESS"
GATEWAY="${OCT1}.${OCT2}.0.1"
SUBNET_MASK="255.255.0.0"
DNS="8.8.8.8"

echo "=========================================="
echo "Ethernet Static IP Configuration"
echo "=========================================="
echo "IP Address:  $IP_ADDRESS"
echo "Subnet Mask: $SUBNET_MASK (/16)"
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
    sudo nmcli con mod "$CONN_NAME" ipv4.addresses "${IP_ADDRESS}/16"
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
static ip_address=${IP_ADDRESS}/16
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
