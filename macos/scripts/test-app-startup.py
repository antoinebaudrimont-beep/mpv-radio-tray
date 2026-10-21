#!/usr/bin/env python3
"""Smoke-test the actual AppKit executable; starts stopped, never selects a station."""
import os
import pathlib
import select
import signal
import subprocess
import sys
import time


def exercise(binary, shutdown_signal):
    process = subprocess.Popen([str(binary)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    messages = []
    try:
        deadline = time.monotonic() + 15
        ready = False
        while time.monotonic() < deadline and process.poll() is None:
            readable, _, _ = select.select([process.stderr], [], [], 1)
            if readable:
                line = os.read(process.stderr.fileno(), 8192).decode("utf-8", errors="replace")
                messages.append(line)
                if "MPV Radio Tray ready" in line:
                    ready = True
                    break
        assert ready, f"App did not finish launching (exit {process.poll()}): " + "".join(messages)
        process.send_signal(shutdown_signal)
        _, remaining = process.communicate(timeout=8)
        messages.append(remaining.decode("utf-8", errors="replace"))
        assert process.returncode == 0, "App did not exit normally: " + "".join(messages)
        assert "Playback stopped for shutdown" in "".join(messages), "App did not complete native playback shutdown"
        print(f"PASS: AppKit launch and {signal.Signals(shutdown_signal).name} shutdown")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=3)
        process.stderr.close()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: test-app-startup.py '/path/to/MPV Radio Tray.app'")
    binary = pathlib.Path(sys.argv[1]).resolve() / "Contents/MacOS/RadioMenuBar"
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        exercise(binary, number)
