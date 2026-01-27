#!/usr/bin/env python3
"""
Lightweight RTSP streamer for Raspberry Pi cameras.
Reads configuration from ~/Desktop/stream.json and streams via MediaMTX.
Uses MediaMTX's native Raspberry Pi camera support.
"""

import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import Optional

# Default config location
CONFIG_PATH = Path.home() / "Desktop" / "stream.json"

@dataclass
class StreamConfig:
    """RTSP stream configuration."""
    resolution: str = "1280x720"
    fps: int = 30
    hostname: str = "0.0.0.0"
    port: int = 8554
    path: str = "stream"
    bitrate: int = 5000000  # Bitrate in bits per second (default 5 Mbps)
    idr_period: int = 15  # Keyframe interval in frames (lower = faster recovery, more bandwidth)

    @property
    def width(self) -> int:
        return int(self.resolution.split("x")[0])

    @property
    def height(self) -> int:
        return int(self.resolution.split("x")[1])

    @property
    def rtsp_url(self) -> str:
        return f"rtsp://{self.hostname}:{self.port}/{self.path}"

    def save(self, path: Path) -> None:
        """Save configuration to JSON file."""
        with open(path, "w") as f:
            json.dump(asdict(self), f, indent=2)

    @classmethod
    def load(cls, path: Path) -> "StreamConfig":
        """Load configuration from JSON file, creating default if missing."""
        if not path.exists():
            config = cls()
            config.save(path)
            print(f"Created default config at {path}")
            return config

        with open(path) as f:
            data = json.load(f)
        return cls(**data)


class RTSPStreamer:
    """Manages the RTSP streaming using MediaMTX's native Pi camera support."""

    def __init__(self, config: StreamConfig):
        self.config = config
        self.mediamtx_proc: Optional[subprocess.Popen] = None
        self.running = False

    def _find_mediamtx(self) -> Optional[str]:
        """Find MediaMTX executable."""
        search_paths = [
            Path(__file__).parent / "mediamtx",
            Path("/usr/local/bin/mediamtx"),
            Path("/usr/bin/mediamtx"),
            Path.home() / "mediamtx" / "mediamtx",
        ]

        for path in search_paths:
            if path.exists() and os.access(path, os.X_OK):
                return str(path)

        # Check PATH
        try:
            result = subprocess.run(
                ["which", "mediamtx"],
                capture_output=True,
                text=True
            )
            if result.returncode == 0:
                return result.stdout.strip()
        except Exception:
            pass

        return None

    def _is_port_open(self, host: str, port: int) -> bool:
        """Check if a port is open."""
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return True
        except Exception:
            return False

    def _wait_for_port(self, host: str, port: int, timeout: float = 10.0) -> bool:
        """Wait for a port to become available."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self._is_port_open(host, port):
                return True
            time.sleep(0.2)
        return False

    def _kill_existing_processes(self) -> None:
        """Kill any existing streaming processes."""
        try:
            subprocess.run(
                ["pkill", "-f", "mediamtx"],
                capture_output=True,
                timeout=5
            )
        except Exception:
            pass
        time.sleep(0.5)

    def _start_mediamtx(self) -> bool:
        """Start MediaMTX with native Pi camera support."""
        mediamtx_path = self._find_mediamtx()
        if not mediamtx_path:
            print("ERROR: MediaMTX not found. Please install it first.")
            return False

        # Configure MediaMTX via environment variables
        # Using native rpiCamera source
        env = os.environ.copy()
        env["MTX_RTSPADDRESS"] = f":{self.config.port}"
        env["MTX_PATHS_" + self.config.path.upper() + "_SOURCE"] = "rpiCamera"
        env["MTX_PATHS_" + self.config.path.upper() + "_RPICAMERAWIDTH"] = str(self.config.width)
        env["MTX_PATHS_" + self.config.path.upper() + "_RPICAMERAHEIGHT"] = str(self.config.height)
        env["MTX_PATHS_" + self.config.path.upper() + "_RPICAMERAFPS"] = str(self.config.fps)
        env["MTX_PATHS_" + self.config.path.upper() + "_RPICAMERAIDRPERIOD"] = str(self.config.idr_period)
        env["MTX_PATHS_" + self.config.path.upper() + "_RPICAMERAPROFILE"] = "baseline"
        env["MTX_PATHS_" + self.config.path.upper() + "_RPICAMERALEVEL"] = "4.1"
        env["MTX_PATHS_" + self.config.path.upper() + "_RPICAMERABITRATE"] = str(self.config.bitrate)

        print(f"Starting MediaMTX on port {self.config.port}...")
        print(f"Resolution: {self.config.resolution}")
        print(f"FPS: {self.config.fps}")
        print(f"Bitrate: {self.config.bitrate // 1000000} Mbps")

        try:
            self.mediamtx_proc = subprocess.Popen(
                [mediamtx_path],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env=env
            )
        except Exception as e:
            print(f"ERROR: Failed to start MediaMTX: {e}")
            return False

        # Wait for RTSP port to be available
        if not self._wait_for_port("127.0.0.1", self.config.port):
            print("ERROR: MediaMTX failed to start (port not available)")
            # Print any output for debugging
            if self.mediamtx_proc.stdout:
                output = self.mediamtx_proc.stdout.read(4096).decode()
                if output:
                    print(f"MediaMTX output: {output}")
            return False

        print("MediaMTX started successfully")
        return True

    def start(self) -> bool:
        """Start the RTSP stream."""
        print("=" * 50)
        print("RPI-RTSP Streamer")
        print("=" * 50)
        print(f"Config: {CONFIG_PATH}")
        print(f"Resolution: {self.config.resolution}")
        print(f"FPS: {self.config.fps}")
        print(f"RTSP URL: rtsp://<pi-ip>:{self.config.port}/{self.config.path}")
        print("=" * 50)

        self._kill_existing_processes()

        if not self._start_mediamtx():
            return False

        self.running = True
        print("Stream started successfully!")
        return True

    def stop(self) -> None:
        """Stop the stream."""
        print("\nStopping stream...")
        self.running = False

        if self.mediamtx_proc and self.mediamtx_proc.poll() is None:
            try:
                self.mediamtx_proc.terminate()
                self.mediamtx_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.mediamtx_proc.kill()
            except Exception:
                pass

        print("Stream stopped")

    def wait(self) -> None:
        """Wait for the streaming process to end."""
        try:
            while self.running:
                if self.mediamtx_proc and self.mediamtx_proc.poll() is not None:
                    print("MediaMTX process ended unexpectedly")
                    break
                time.sleep(1)
        except KeyboardInterrupt:
            pass


def main():
    # Load configuration
    config = StreamConfig.load(CONFIG_PATH)

    # Create streamer
    streamer = RTSPStreamer(config)

    # Set up signal handlers for graceful shutdown
    def signal_handler(sig, frame):
        streamer.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Start streaming
    if not streamer.start():
        print("Failed to start streaming")
        sys.exit(1)

    # Wait for stream to end
    streamer.wait()
    streamer.stop()


if __name__ == "__main__":
    main()
