#!/usr/bin/env python3
"""Render and atomically apply one Frigate Tapo camera block."""

import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.parse import quote


def validate(settings):
    if not re.fullmatch(r"[A-Za-z0-9_]+", settings["name"]):
        raise ValueError("camera name must contain only letters, numbers, and underscores")
    address = ipaddress.ip_address(settings["ip"])
    private_lans = (ipaddress.ip_network("10.0.0.0/8"), ipaddress.ip_network("172.16.0.0/12"),
                    ipaddress.ip_network("192.168.0.0/16"))
    if address.version != 4 or not any(address in network for network in private_lans):
        raise ValueError("camera IP must be a private IPv4 address")
    for key in ("rtsp_port", "onvif_port"):
        if not re.fullmatch(r"[0-9]{1,5}", settings[key]) or not 1 <= int(settings[key]) <= 65535:
            raise ValueError(f"{key} must be an integer from 1 through 65535")
    for key in ("width", "height", "fps"):
        if not re.fullmatch(r"[0-9]{1,4}", settings[key]) or int(settings[key]) < 1:
            raise ValueError(f"{key} must be a positive integer")
    for key in ("record_path", "detect_path"):
        path = settings[key]
        if (not re.fullmatch(r"/[A-Za-z0-9._~/-]*", path)
                or any(part == ".." for part in path.split("/"))):
            raise ValueError(f"{key} must be a simple absolute RTSP path")
    for key in ("username", "password"):
        value = settings[key]
        if not value or any(char in value for char in ("\r", "\n", "\0")):
            raise ValueError(f"camera {key} must be non-empty and contain no line breaks")


def render(original, settings):
    validate(settings)
    lines = original.splitlines()
    name = settings["name"]
    camera_block = [
        f"  {name}:",
        "    enabled: true",
        "    ffmpeg:",
        "      inputs:",
        f"        - path: {make_rtsp(settings, settings['record_path'])}",
        "          input_args: preset-rtsp-generic",
        "          roles:",
        "            - record",
        f"        - path: {make_rtsp(settings, settings['detect_path'])}",
        "          input_args: preset-rtsp-generic",
        "          roles:",
        "            - detect",
        "    onvif:",
        f"      host: {settings['ip']}",
        f"      port: {settings['onvif_port']}",
        f"      user: {json.dumps(settings['username'])}",
        f"      password: {json.dumps(settings['password'])}",
        "    detect:",
        "      enabled: true",
        f"      width: {settings['width']}",
        f"      height: {settings['height']}",
        f"      fps: {settings['fps']}",
        "    record:",
        "      enabled: true",
        "    snapshots:",
        "      enabled: true",
    ]
    camera_key = f"  {name}:"
    camera_sections = [i for i, line in enumerate(lines)
                       if re.fullmatch(r"cameras:\s*(?:\{\})?\s*", line)]
    if len(camera_sections) > 1:
        raise ValueError("multiple top-level cameras sections found")
    cameras_index = camera_sections[0] if camera_sections else None
    if cameras_index is None:
        insert_at = next((i for i, line in enumerate(lines) if line.startswith("version:")), len(lines))
        result = lines[:insert_at] + ["cameras:"] + camera_block + lines[insert_at:]
    elif "{}" in lines[cameras_index]:
        result = lines[:cameras_index] + ["cameras:"] + camera_block + lines[cameras_index + 1:]
    else:
        section_end = len(lines)
        for i in range(cameras_index + 1, len(lines)):
            if lines[i] and not lines[i].startswith(" "):
                section_end = i
                break
        camera_start = next((i for i in range(cameras_index + 1, section_end)
                             if lines[i] == camera_key), None)
        if sum(lines[i] == camera_key for i in range(cameras_index + 1, section_end)) > 1:
            raise ValueError(f"multiple camera blocks found for {name}")
        if camera_start is not None:
            camera_end = section_end
            for i in range(camera_start + 1, section_end):
                if re.match(r"^  [A-Za-z0-9_]+:$", lines[i]):
                    camera_end = i
                    break
            result = lines[:camera_start] + camera_block + lines[camera_end:]
        else:
            insertion = section_end
            prefix = lines[:insertion]
            if insertion > 0 and prefix[-1] != "":
                prefix.append("")
            result = prefix + camera_block + lines[insertion:]
    return "\n".join(result).rstrip() + "\n"


def make_rtsp(settings, path):
    username = quote(settings["username"], safe="")
    password = quote(settings["password"], safe="")
    return f"rtsp://{username}:{password}@{settings['ip']}:{settings['rtsp_port']}{path}"


def atomic_write(path, content):
    info = path.stat(follow_symlinks=False)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.step10g.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp_name, info.st_mode & 0o7777)
        os.chown(temp_name, info.st_uid, info.st_gid)
        os.replace(temp_name, path)
    except Exception:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


def main():
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--dry-run"):
        raise ValueError("usage: helper CONFIG [--dry-run]")
    fields = sys.stdin.buffer.read().split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    keys = ("name", "ip", "username", "password", "rtsp_port", "record_path",
            "detect_path", "width", "height", "fps", "onvif_port")
    if len(fields) != len(keys):
        raise ValueError("incomplete camera settings received")
    settings = dict(zip(keys, (field.decode("utf-8") for field in fields)))
    config = Path(sys.argv[1])
    if config.is_symlink() or not config.is_file():
        raise ValueError("Frigate config must be a regular file, not a symbolic link")
    original = config.read_text(encoding="utf-8")
    updated = render(original, settings)
    if updated == original:
        print("UNCHANGED")
    elif len(sys.argv) == 3:
        print("DRY-RUN: camera settings would change; no file was written")
    else:
        atomic_write(config, updated)
        print("CHANGED")


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError) as error:
        print(f"frigate-camera-config: {error}", file=sys.stderr)
        raise SystemExit(1)
