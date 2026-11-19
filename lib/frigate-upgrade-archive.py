#!/usr/bin/env python3
"""Reject unsafe or unrelated members in a Step 18B Frigate archive."""

import sys
import tarfile
from pathlib import PurePosixPath


def validate(archive: str, compose_path: str, config_path: str) -> None:
    compose = PurePosixPath(compose_path)
    config = PurePosixPath(config_path)
    if compose.is_absolute() or config.is_absolute() or ".." in compose.parts or ".." in config.parts:
        raise ValueError("expected Compose/config paths must be safe relative paths")
    found_compose = False
    found_config = False
    seen: set[str] = set()
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle.getmembers():
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts or not name.parts:
                raise ValueError(f"unsafe archive member path: {member.name!r}")
            normalized = str(name)
            if normalized in seen:
                raise ValueError(f"duplicate archive member: {normalized}")
            seen.add(normalized)
            if normalized == str(compose):
                found_compose = member.isfile()
            elif normalized == str(config):
                found_config = member.isdir()
            elif not normalized.startswith(f"{config}/"):
                raise ValueError(f"unexpected archive member: {normalized}")
            if not (member.isfile() or member.isdir()):
                raise ValueError(f"links and special files are not allowed: {normalized}")
    if not found_compose or not found_config:
        raise ValueError("archive is missing the expected Compose file or config directory")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: archive.py ARCHIVE RELATIVE_COMPOSE RELATIVE_CONFIG")
    try:
        validate(*sys.argv[1:])
    except (OSError, tarfile.TarError, ValueError) as exc:
        raise SystemExit(str(exc))
    print("ARCHIVE SAFE")
