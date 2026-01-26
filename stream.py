#!/usr/bin/env python3
"""
Lightweight RTSP streamer for Raspberry Pi cameras.
Reads configuration from ~/Desktop/stream.json and streams via MediaMTX.
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
    """Manages the RTSP streaming pipeline."""

    def __init__(self, config: StreamConfig):
        self.config = config
        self.rpicam_proc: Optional[subprocess.Popen] = None
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
        for proc_name in ["mediamtx", "rpicam-vid"]:
            try:
                subprocess.run(
                    ["pkill", "-f", proc_name],
                    capture_output=True,
                    timeout=5
                )
            except Exception:
                pass
        time.sleep(0.5)

    def _start_mediamtx(self) -> bool:
        """Start the MediaMTX RTSP server."""
        mediamtx_path = self._find_mediamtx()
        if not mediamtx_path:
            print("ERROR: MediaMTX not found. Please install it first.")
            return False

        # Build MediaMTX command with inline config
        cmd = [
            mediamtx_path,
        ]

        # Set environment for MediaMTX configuration
        env = os.environ.copy()
        env["MTX_PROTOCOLS"] = "tcp"
        env["MTX_RTSPADDRESS"] = f":{self.config.port}"

        print(f"Starting MediaMTX on port {self.config.port}...")

        try:
            self.mediamtx_proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env
            )
        except Exception as e:
            print(f"ERROR: Failed to start MediaMTX: {e}")
            return False

        # Wait for RTSP port to be available
        if not self._wait_for_port("127.0.0.1", self.config.port):
            print("ERROR: MediaMTX failed to start (port not available)")
            return False

        print("MediaMTX started successfully")
        return True

    def _start_rpicam(self) -> bool:
        """Start rpicam-vid to capture and stream."""
        # Build rpicam-vid command
        # Output to stdout in H.264 format, pipe to ffmpeg for RTSP
        rtsp_target = f"rtsp://127.0.0.1:{self.config.port}/{self.config.path}"

        # Use rpicam-vid with inline output to ffmpeg
        rpicam_cmd = [
            "rpicam-vid",
            "-t", "0",  # Run indefinitely
            "-n",  # No preview window
            "--width", str(self.config.width),
            "--height", str(self.config.height),
            "--framerate", str(self.config.fps),
            "--codec", "h264",
            "--libav-format", "h264",  # Raw H.264 output format
            "--profile", "baseline",
            "--level", "4.1",
            "--intra", "15",  # IDR frame interval
            "--inline",  # Insert SPS/PPS with each IDR
            "-o", "-",  # Output to stdout
        ]

        # FFmpeg command to receive H.264 and push to RTSP
        ffmpeg_cmd = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel", "warning",
            "-f", "h264",
            "-i", "-",  # Read from stdin
            "-c:v", "copy",  # No re-encoding
            "-f", "rtsp",
            "-rtsp_transport", "tcp",
            rtsp_target,
        ]

        print(f"Starting camera stream: {self.config.resolution} @ {self.config.fps}fps")
        print(f"RTSP URL: {rtsp_target}")

        try:
            # Start rpicam-vid, pipe to ffmpeg
            self.rpicam_proc = subprocess.Popen(
                rpicam_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE
            )

            self.ffmpeg_proc = subprocess.Popen(
                ffmpeg_cmd,
                stdin=self.rpicam_proc.stdout,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE
            )

            # Allow rpicam stdout to be consumed by ffmpeg
            self.rpicam_proc.stdout.close()

        except FileNotFoundError as e:
            print(f"ERROR: Required tool not found: {e}")
            print("Make sure rpicam-vid and ffmpeg are installed.")
            return False
        except Exception as e:
            print(f"ERROR: Failed to start streaming: {e}")
            return False

        time.sleep(2)  # Give it time to initialize

        if self.rpicam_proc.poll() is not None:
            stderr = self.rpicam_proc.stderr.read().decode() if self.rpicam_proc.stderr else ""
            print(f"ERROR: rpicam-vid exited unexpectedly: {stderr}")
            return False

        print("Stream started successfully!")
        return True

    def start(self) -> bool:
        """Start the complete streaming pipeline."""
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

        if not self._start_rpicam():
            self.stop()
            return False

        self.running = True
        return True

    def stop(self) -> None:
        """Stop all streaming processes."""
        print("\nStopping stream...")
        self.running = False

        for proc, name in [
            (getattr(self, 'ffmpeg_proc', None), "ffmpeg"),
            (self.rpicam_proc, "rpicam-vid"),
            (self.mediamtx_proc, "mediamtx"),
        ]:
            if proc and proc.poll() is None:
                try:
                    proc.terminate()
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                except Exception:
                    pass

        print("Stream stopped")

    def wait(self) -> None:
        """Wait for the streaming process to end."""
        try:
            while self.running:
                # Check if processes are still running
                if hasattr(self, 'ffmpeg_proc') and self.ffmpeg_proc.poll() is not None:
                    print("FFmpeg process ended unexpectedly")
                    break
                if self.rpicam_proc and self.rpicam_proc.poll() is not None:
                    print("rpicam-vid process ended unexpectedly")
                    break
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
