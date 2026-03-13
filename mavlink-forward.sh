#!/bin/bash
#
# MAVLink TCP Forwarder
# Detects an ArduPilot flight controller connected via USB serial
# and forwards the MAVLink stream over TCP.
#
# Usage: bash mavlink-forward.sh [tcp_port]
# Default TCP port: 5760
#

set -e

TCP_PORT="${1:-5760}"
BAUD_RATE=115200

echo "=========================================="
echo "MAVLink TCP Forwarder"
echo "=========================================="
echo "TCP Port:  $TCP_PORT"
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
    echo "$(date): Serving MAVLink from $device on TCP port $TCP_PORT"

    # Configure serial port
    stty -F "$device" "$BAUD_RATE" raw -echo -echoe -echok -echoctl -echoke

    # Forward serial data over TCP (Pi acts as server, clients connect to this port)
    socat "FILE:${device},b${BAUD_RATE},raw" "TCP4-LISTEN:${TCP_PORT},reuseaddr,fork" 2>&1
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
