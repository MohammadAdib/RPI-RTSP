# RPI-RTSP

Lightweight RTSP streamer for Raspberry Pi cameras. Automatically streams your Pi camera over RTSP on boot.

## Features

- Streams Raspberry Pi camera via RTSP protocol
- Configurable resolution, FPS, hostname, port, and path
- Auto-starts on boot via systemd
- Low latency H.264 streaming
- Configuration file on Desktop for easy editing

## Requirements

- Raspberry Pi (tested on Pi 4/5, should work on Pi 3)
- Raspberry Pi Camera Module (v1, v2, v3, or HQ Camera)
- Raspbian OS (Bookworm or newer recommended)

## Quick Setup (Automated)

```bash
# Clone this repository
git clone https://github.com/YourUsername/RPI-RTSP.git ~/RPI-RTSP

# Run the setup script
cd ~/RPI-RTSP
bash setup.sh
```

The script will:
- Install dependencies (ffmpeg, rpicam-apps)
- Download and install MediaMTX
- Create the config file at `~/Desktop/stream.json`
- Set up the systemd service for auto-start on boot

After setup, enable the camera if not already done:
```bash
sudo raspi-config
# Navigate to: Interface Options → Camera → Enable
sudo reboot
```

After reboot, the stream starts automatically at: `rtsp://<pi-ip>:8554/stream`

---

## Manual Setup

### 1. Enable the Camera

```bash
sudo raspi-config
```

Navigate to: **Interface Options** → **Camera** → **Enable**

Reboot if prompted.

### 2. Install MediaMTX

```bash
# Download MediaMTX (check for latest version at https://github.com/bluenviron/mediamtx/releases)
# For Raspberry Pi 4/5 (64-bit):
wget https://github.com/bluenviron/mediamtx/releases/download/v1.9.3/mediamtx_v1.9.3_linux_arm64v8.tar.gz

# For Raspberry Pi 3 or 32-bit OS:
# wget https://github.com/bluenviron/mediamtx/releases/download/v1.9.3/mediamtx_v1.9.3_linux_armv7.tar.gz

# Extract
tar -xzf mediamtx_v1.9.3_linux_arm64v8.tar.gz

# Move to /usr/local/bin
sudo mv mediamtx /usr/local/bin/
sudo chmod +x /usr/local/bin/mediamtx
```

### 3. Install the Streaming Script

```bash
# Clone this repository
git clone https://github.com/YourUsername/RPI-RTSP.git ~/RPI-RTSP

# Make script executable
chmod +x ~/RPI-RTSP/stream.py
```

### 4. Create Configuration File

The script will auto-create a default config on first run, or you can create it manually:

```bash
cat > ~/Desktop/stream.json << 'EOF'
{
  "resolution": "1280x720",
  "fps": 30,
  "hostname": "0.0.0.0",
  "port": 8554,
  "path": "stream"
}
EOF
```

### 5. Test the Stream

```bash
# Run manually first to verify everything works
python3 ~/RPI-RTSP/stream.py
```

You should see output like:
```
==================================================
RPI-RTSP Streamer
==================================================
Config: /home/pi/Desktop/stream.json
Resolution: 1280x720
FPS: 30
RTSP URL: rtsp://<pi-ip>:8554/stream
==================================================
Starting MediaMTX on port 8554...
MediaMTX started successfully
Starting camera stream: 1280x720 @ 30fps
Stream started successfully!
```

Press `Ctrl+C` to stop.

### 6. Set Up Auto-Start on Boot

Create a systemd service:

```bash
sudo tee /etc/systemd/system/rpi-rtsp.service << 'EOF'
[Unit]
Description=RPI RTSP Camera Streamer
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/RPI-RTSP
ExecStart=/usr/bin/python3 /home/pi/RPI-RTSP/stream.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

> **Note:** Replace `pi` with your username if different (check with `whoami`)

Enable and start the service:

```bash
# Reload systemd
sudo systemctl daemon-reload

# Enable auto-start on boot
sudo systemctl enable rpi-rtsp

# Start the service now
sudo systemctl start rpi-rtsp

# Check status
sudo systemctl status rpi-rtsp
```

## Viewing the Stream

Once running, you can view the stream from any device on your network:

### VLC Media Player

1. Open VLC
2. Go to **Media** → **Open Network Stream**
3. Enter: `rtsp://<raspberry-pi-ip>:8554/stream`

### FFplay

```bash
ffplay rtsp://<raspberry-pi-ip>:8554/stream
```

### OBS Studio

1. Add a **Media Source**
2. Uncheck "Local File"
3. Enter: `rtsp://<raspberry-pi-ip>:8554/stream`

Find your Pi's IP address with:
```bash
hostname -I
```

## Configuration Options

Edit `~/Desktop/stream.json` to customize:

| Option | Description | Default | Example Values |
|--------|-------------|---------|----------------|
| `resolution` | Video resolution | `1280x720` | `640x480`, `1920x1080`, `2560x1440` |
| `fps` | Frames per second | `30` | `15`, `24`, `25`, `30`, `60` |
| `hostname` | Bind address | `0.0.0.0` | `0.0.0.0` (all interfaces), `192.168.1.x` |
| `port` | RTSP port | `8554` | Any available port |
| `path` | Stream path | `stream` | `live`, `camera`, `video` |

After editing, restart the service:

```bash
sudo systemctl restart rpi-rtsp
```

## Useful Commands

```bash
# View service logs
sudo journalctl -u rpi-rtsp -f

# Restart the stream
sudo systemctl restart rpi-rtsp

# Stop the stream
sudo systemctl stop rpi-rtsp

# Disable auto-start
sudo systemctl disable rpi-rtsp

# Check if stream is running
sudo systemctl status rpi-rtsp
```

## Troubleshooting

### Camera not detected

```bash
# Check if camera is detected
rpicam-hello --list-cameras

# If no cameras found:
# 1. Ensure camera cable is properly connected
# 2. Enable camera in raspi-config
# 3. Reboot
```

### Stream not accessible from network

```bash
# Check if service is running
sudo systemctl status rpi-rtsp

# Check if port is open
sudo netstat -tlnp | grep 8554

# Ensure firewall allows traffic (if enabled)
sudo ufw allow 8554/tcp
```

### High latency

Try reducing resolution or FPS in `stream.json`:

```json
{
  "resolution": "640x480",
  "fps": 15
}
```

### Permission errors

Ensure your user is in the `video` group:

```bash
sudo usermod -aG video $USER
# Log out and back in for changes to take effect
```

## Performance Tips

- **720p @ 30fps** is recommended for a good balance of quality and performance
- **1080p** may work but could increase latency on Pi 3
- Use **wired Ethernet** instead of WiFi for more stable streaming
- Keep the Pi adequately cooled for sustained streaming

## License

MIT License
