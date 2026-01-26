#!/bin/bash
#
# RPI-RTSP Setup Script
# Run this on a fresh Raspbian install to set up RTSP streaming
#

set -e

echo "=========================================="
echo "RPI-RTSP Setup Script"
echo "=========================================="

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo "Please run without sudo (script will request sudo when needed)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USERNAME="$(whoami)"
HOME_DIR="$HOME"

echo "User: $USERNAME"
echo "Home: $HOME_DIR"
echo "Script directory: $SCRIPT_DIR"
echo ""

# Detect architecture
ARCH=$(uname -m)
echo "Architecture: $ARCH"

if [ "$ARCH" = "aarch64" ]; then
    MEDIAMTX_URL="https://github.com/bluenviron/mediamtx/releases/download/v1.9.3/mediamtx_v1.9.3_linux_arm64v8.tar.gz"
elif [ "$ARCH" = "armv7l" ]; then
    MEDIAMTX_URL="https://github.com/bluenviron/mediamtx/releases/download/v1.9.3/mediamtx_v1.9.3_linux_armv7.tar.gz"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

echo ""
echo "[1/6] Updating package list..."
sudo apt update

echo ""
echo "[2/6] Installing dependencies (ffmpeg, libcamera-apps)..."
sudo apt install -y ffmpeg libcamera-apps

echo ""
echo "[3/6] Installing MediaMTX..."
if command -v mediamtx &> /dev/null; then
    echo "MediaMTX already installed, skipping..."
else
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    echo "Downloading MediaMTX..."
    wget -q --show-progress "$MEDIAMTX_URL" -O mediamtx.tar.gz
    tar -xzf mediamtx.tar.gz
    sudo mv mediamtx /usr/local/bin/
    sudo chmod +x /usr/local/bin/mediamtx
    cd "$SCRIPT_DIR"
    rm -rf "$TEMP_DIR"
    echo "MediaMTX installed to /usr/local/bin/mediamtx"
fi

echo ""
echo "[4/6] Setting up stream script..."
chmod +x "$SCRIPT_DIR/stream.py"

echo ""
echo "[5/6] Creating config file..."
CONFIG_FILE="$HOME_DIR/Desktop/stream.json"
if [ -f "$CONFIG_FILE" ]; then
    echo "Config already exists at $CONFIG_FILE, skipping..."
else
    mkdir -p "$HOME_DIR/Desktop"
    cat > "$CONFIG_FILE" << 'EOF'
{
  "resolution": "1280x720",
  "fps": 30,
  "hostname": "0.0.0.0",
  "port": 8554,
  "path": "stream"
}
EOF
    echo "Created config at $CONFIG_FILE"
fi

echo ""
echo "[6/6] Setting up systemd service..."
sudo tee /etc/systemd/system/rpi-rtsp.service > /dev/null << EOF
[Unit]
Description=RPI RTSP Camera Streamer
After=network.target

[Service]
Type=simple
User=$USERNAME
WorkingDirectory=$SCRIPT_DIR
ExecStart=/usr/bin/python3 $SCRIPT_DIR/stream.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable rpi-rtsp
echo "Systemd service created and enabled"

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo ""
echo "1. Ensure camera is enabled:"
echo "   sudo raspi-config -> Interface Options -> Camera -> Enable"
echo ""
echo "2. Reboot if you just enabled the camera:"
echo "   sudo reboot"
echo ""
echo "3. After reboot, the stream will start automatically."
echo "   Or start it now with: sudo systemctl start rpi-rtsp"
echo ""
echo "4. View stream at: rtsp://$(hostname -I | awk '{print $1}'):8554/stream"
echo ""
echo "5. Edit config at: $CONFIG_FILE"
echo ""
