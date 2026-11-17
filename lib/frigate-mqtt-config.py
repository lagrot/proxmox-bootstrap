#!/usr/bin/env python3
"""Safely update Frigate's top-level MQTT connection settings."""
import argparse
import ipaddress
import os
from pathlib import Path
import re
import stat
import tempfile


def render(text: str, host: str, port: str) -> str:
    """Return config text with MQTT connection settings updated, preserving peers."""
    ipaddress.IPv4Address(host)
    numeric_port = int(port)
    if not 1 <= numeric_port <= 65535:
        raise ValueError("MQTT port must be between 1 and 65535")

    lines = text.splitlines()
    mqtt_candidates = [i for i, line in enumerate(lines) if line.startswith("mqtt:")]
    headers = [i for i in mqtt_candidates
               if re.fullmatch(r"mqtt:[ \t]*(?:#.*)?", lines[i])
               or re.fullmatch(r"mqtt:[ \t]*\{[ \t]*\}[ \t]*(?:#.*)?", lines[i])]
    if len(mqtt_candidates) > len(headers):
        raise ValueError("Frigate config has an unsupported inline mqtt value")
    if len(headers) > 1:
        raise ValueError("Frigate config contains multiple top-level mqtt sections")

    target = {"enabled": "true", "host": host, "port": str(numeric_port)}
    if not headers:
        lines = ["mqtt:", *(f"  {key}: {value}" for key, value in target.items()), "", *lines]
    else:
        start = headers[0]
        if "{" in lines[start]:
            comment = re.search(r"[ \t]+#.*$", lines[start])
            lines[start] = "mqtt:" + (" " + comment.group(0).lstrip() if comment else "")
        end = next((i for i in range(start + 1, len(lines))
                    if lines[i] and not lines[i][0].isspace()
                    and not lines[i].startswith("#")), len(lines))
        seen = {key: [] for key in target}
        for i in range(start + 1, end):
            match = re.match(r"^  (enabled|host|port):(?:[ \t].*)?$", lines[i])
            if match:
                seen[match.group(1)].append(i)
        duplicates = [key for key, indexes in seen.items() if len(indexes) > 1]
        if duplicates:
            raise ValueError("Frigate MQTT section has duplicate keys: " + ", ".join(duplicates))

        for key, indexes in seen.items():
            if indexes:
                i = indexes[0]
                comment = re.search(r"[ \t]+#.*$", lines[i])
                suffix = comment.group(0) if comment else ""
                lines[i] = f"  {key}: {target[key]}{suffix}"

        missing = [key for key in target if not seen[key]]
        for offset, key in enumerate(missing, start=1):
            lines.insert(start + offset, f"  {key}: {target[key]}")

    rendered = "\n".join(lines)
    if not text and rendered.endswith("\n"):
        return rendered
    return rendered + ("\n" if text.endswith("\n") else "")


def atomic_write(path: Path, content: str) -> None:
    """Replace a config atomically while retaining its owner and permissions."""
    original = path.stat()
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chown(temporary, original.st_uid, original.st_gid)
        os.chmod(temporary, stat.S_IMODE(original.st_mode))
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    parser.add_argument("host")
    parser.add_argument("port")
    parser.add_argument("--check", action="store_true", help="report whether a change is needed")
    args = parser.parse_args()

    if args.config.is_symlink():
        raise ValueError("Frigate config path must not be a symbolic link")
    original = args.config.read_text(encoding="utf-8")
    updated = render(original, args.host, args.port)
    if updated == original:
        print("unchanged")
        return 0
    if args.check:
        print("changed")
        return 0
    atomic_write(args.config, updated)
    print("updated")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        raise SystemExit(f"Frigate MQTT config update failed: {error}")
