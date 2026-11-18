#!/usr/bin/env python3
"""Render and atomically apply Frigate's managed global record section."""

import os
from pathlib import Path
import re
import stat
import sys
import tempfile


MANAGED_KEYS = {
    2: {"enabled", "continuous", "motion", "alerts", "detections"},
    4: {"days", "pre_capture", "post_capture", "retain"},
    6: {"days", "mode"},
}


def render(original, days, pre_capture, post_capture):
    lines = original.splitlines()
    starts = [i for i, line in enumerate(lines) if re.match(r"^record\s*:", line)]
    if len(starts) > 1:
        raise ValueError("multiple top-level record sections found; refusing ambiguous edit")
    record = [
        "record:", "  enabled: true", "  continuous:", "    days: 0", "  motion:",
        "    days: 0", "  alerts:", f"    pre_capture: {pre_capture}",
        f"    post_capture: {post_capture}", "    retain:", f"      days: {days}",
        "      mode: motion", "  detections:", f"    pre_capture: {pre_capture}",
        f"    post_capture: {post_capture}", "    retain:", f"      days: {days}",
        "      mode: motion",
    ]
    if starts:
        start = starts[0]
        end = next(
            (i for i in range(start + 1, len(lines)) if line_is_top_level(lines[i])),
            len(lines),
        )
        while end > start + 1 and not lines[end - 1].strip():
            end -= 1
        for line in lines[start + 1:end]:
            if not line.strip():
                continue
            match = re.match(r"^( *)([A-Za-z_][A-Za-z0-9_-]*)\s*:", line)
            if not match or len(match.group(1)) not in MANAGED_KEYS:
                raise ValueError("record section contains unsupported syntax; refusing to discard settings")
            indent = len(match.group(1))
            if match.group(2) not in MANAGED_KEYS[indent]:
                raise ValueError("record section contains unmanaged keys; refusing to discard settings")
        prefix = lines[:start]
        while prefix and not prefix[-1].strip():
            prefix.pop()
        suffix = lines[end:]
        while suffix and not suffix[0].strip():
            suffix.pop(0)
        changed = (prefix + ([""] if prefix else []) + record
                   + ([""] if suffix else []) + suffix)
    else:
        anchor = next((i for i, line in enumerate(lines)
                       if re.match(r"^(snapshots|cameras|version)\s*:", line)), len(lines))
        prefix = lines[:anchor]
        if prefix and prefix[-1] != "":
            prefix.append("")
        changed = prefix + record + ([""] if anchor < len(lines) else []) + lines[anchor:]
    return "\n".join(changed).rstrip() + "\n"


def line_is_top_level(line):
    return bool(line and not line.startswith((" ", "\t", "#")))


def atomic_write(path, content):
    info = path.stat(follow_symlinks=False)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.step10o.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp_name, stat.S_IMODE(info.st_mode))
        os.chown(temp_name, info.st_uid, info.st_gid)
        os.replace(temp_name, path)
    except Exception:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


def main():
    if len(sys.argv) == 4 and sys.argv[2] == "--restore":
        config = Path(sys.argv[1])
        backup = Path(sys.argv[3])
        if config.is_symlink() or not config.is_file() or backup.is_symlink() or not backup.is_file():
            raise ValueError("restore requires regular config and backup files")
        atomic_write(config, backup.read_text(encoding="utf-8"))
        print("RESTORED")
        return
    if len(sys.argv) not in (5, 6, 7) or (len(sys.argv) == 6 and sys.argv[5] != "--dry-run"):
        if len(sys.argv) != 7 or sys.argv[5] != "--backup":
            raise ValueError("usage: helper CONFIG DAYS PRE_CAPTURE POST_CAPTURE [--dry-run | --backup PATH] or CONFIG --restore BACKUP")
    config = Path(sys.argv[1])
    if config.is_symlink() or not config.is_file():
        raise ValueError("config must be a regular file, not a symbolic link")
    numbers = sys.argv[2:5]
    if any(not re.fullmatch(r"[0-9]+", number) for number in numbers) or int(numbers[0]) < 1:
        raise ValueError("retention days must be positive and capture seconds non-negative integers")
    original = config.read_text(encoding="utf-8")
    updated = render(original, *numbers)
    if updated == original:
        print("UNCHANGED")
    elif len(sys.argv) == 6:
        print("DRY-RUN: recording policy would change; no file was written")
    else:
        backup = Path(sys.argv[6])
        backup_fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(backup_fd, "wb") as stream:
                stream.write(original.encode("utf-8"))
                stream.flush()
                os.fsync(stream.fileno())
        except Exception:
            try:
                backup.unlink()
            except FileNotFoundError:
                pass
            raise
        atomic_write(config, updated)
        print("CHANGED")


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError) as error:
        print(f"frigate-event-recording-config: {error}", file=sys.stderr)
        raise SystemExit(1)
