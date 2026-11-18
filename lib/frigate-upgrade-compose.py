#!/usr/bin/env python3
"""Safely inspect or atomically update the Frigate image in Compose YAML."""

import argparse
import os
from pathlib import Path
import re
import stat
import tempfile


def read_compose(path: Path) -> tuple[bytes, int, int, int]:
    if path.is_symlink() or not path.is_file():
        raise ValueError("Compose path must be a regular, non-symlink file")
    info = path.stat(follow_symlinks=False)
    return path.read_bytes(), info.st_mode, info.st_uid, info.st_gid


def image_entries(content: bytes) -> list[tuple[int, bytes, bytes]]:
    entries = []
    for index, line in enumerate(content.splitlines()):
        match = re.fullmatch(rb"(\s*)image:\s*(.*?)\s*", line)
        if match:
            entries.append((index, match.group(1), match.group(2)))
    return entries


def check_image(path: Path, expected: str) -> None:
    content, _, _, _ = read_compose(path)
    entries = image_entries(content)
    if len(entries) != 1 or entries[0][2] != expected.encode():
        raise ValueError("Compose must contain exactly one image entry matching the expected image")


def replace_image(path: Path, old: str, new: str) -> None:
    content, mode, uid, gid = read_compose(path)
    entries = image_entries(content)
    if len(entries) != 1 or entries[0][2] != old.encode():
        raise ValueError("Compose must contain exactly one image entry matching the current image")
    lines = content.splitlines(keepends=True)
    index, indent, _ = entries[0]
    ending = b"\n" if lines[index].endswith(b"\n") else b""
    lines[index] = indent + b"image: " + new.encode() + ending
    updated = b"".join(lines)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(updated)
            stream.flush()
            os.fsync(stream.fileno())
        os.chown(temp_path, uid, gid)
        os.chmod(temp_path, stat.S_IMODE(mode))
        os.replace(temp_path, path)
        dir_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("compose_file", type=Path)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--check-image", metavar="IMAGE")
    actions.add_argument("--replace-image", nargs=2, metavar=("OLD_IMAGE", "NEW_IMAGE"))
    args = parser.parse_args()
    try:
        if args.check_image:
            check_image(args.compose_file, args.check_image)
            print("MATCH")
        else:
            replace_image(args.compose_file, *args.replace_image)
            print("CHANGED")
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
