#!/usr/bin/env python3
"""Run a bounded Frigate camera RTSP probe without writing media files."""

import subprocess
import sys
from urllib.parse import quote


def build_url(username, password, address, port, path):
    return f"rtsp://{quote(username, safe='')}:{quote(password, safe='')}@{address}:{port}{path}"


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: frigate-rtsp-smoke.py FFMPEG_PATH")
    values = sys.stdin.buffer.read().split(b"\0")
    if values and values[-1] == b"":
        values.pop()
    if len(values) != 5:
        raise SystemExit("incomplete camera settings received")
    username, password, address, port, path = (value.decode("utf-8") for value in values)
    url = build_url(username, password, address, port, path)
    result = subprocess.run(
        ["timeout", "15", sys.argv[1], "-hide_banner", "-loglevel", "error",
         "-rtsp_transport", "tcp", "-i", url, "-t", "1", "-f", "null", "-"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
