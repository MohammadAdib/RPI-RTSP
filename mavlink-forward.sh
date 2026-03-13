#!/bin/bash
#
# MAVLink UDP Forwarder
# Detects an ArduPilot flight controller connected via USB serial
# and forwards the MAVLink stream over UDP.
#
# Usage: bash mavlink-forward.sh [udp_port]
# Default UDP port: 14550
#

set -e

UDP_PORT="${1:-14550}"
UDP_DEST="0.0.0.0"
BAUD_RATE=115200

echo "=========================================="
echo "MAVLink UDP Forwarder"
echo "=========================================="
echo "UDP Port:  $UDP_PORT"
echo "Baud Rate: $BAUD_RATE"
echo "=========================================="

# Find a MAVLink serial device (ArduPilot flight controller)
find_serial_device() {
    # Common USB serial devices for flight controllers
    for pattern in /dev/ttyACM* /dev/ttyUSB*; do
        for dev in $pattern; do
            if [ -e "$dev" ]; then
                echo "$dev"
                return 0
            fi
        done
    done
    return 1
}

forward_mavlink() {
    local device="$1"
    echo "$(date): Forwarding MAVLink from $device to UDP port $UDP_PORT"

    # Configure serial port
    stty -F "$device" "$BAUD_RATE" raw -echo -echoe -echok -echoctl -echoke

    # Forward serial data to UDP using socat
    socat "FILE:${device},b${BAUD_RATE},raw" "UDP4-DATAGRAM:${UDP_DEST}:${UDP_PORT},broadcast" 2>&1
}

echo "Watching for flight controller..."
echo ""

while true; do
    DEVICE=$(find_serial_device) || true

    if [ -n "$DEVICE" ]; then
        echo "$(date): Found device: $DEVICE"
        forward_mavlink "$DEVICE" || true
        echo "$(date): Connection lost, waiting for reconnect..."
    fi

    sleep 2
done
