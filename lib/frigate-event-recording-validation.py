#!/usr/bin/env python3
"""Validate the event-recording fields in Frigate's effective API config."""

import json
import math
import sys


def numeric(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def validate_record(record, context, days, pre_capture, post_capture):
    errors = []
    if not isinstance(record, dict):
        return [f"{context}: record settings are missing or invalid"]
    if record.get("enabled") is not True:
        errors.append(f"{context}: recording is disabled or invalid")
    for category in ("continuous", "motion"):
        retention = record.get(category)
        actual = retention.get("days") if isinstance(retention, dict) else None
        if not numeric(actual) or actual != 0:
            errors.append(f"{context}: {category} retention is not zero")
    for event_type in ("alerts", "detections"):
        event = record.get(event_type)
        if not isinstance(event, dict):
            event = {}
        retain = event.get("retain")
        if not isinstance(retain, dict):
            retain = {}
        actual_days = retain.get("days")
        if not numeric(actual_days) or actual_days != days:
            errors.append(f"{context}: {event_type} retention is not {days:g} days")
        if retain.get("mode") != "motion":
            errors.append(f"{context}: {event_type} retention mode is not motion")
        actual_pre = event.get("pre_capture")
        if not numeric(actual_pre) or actual_pre != pre_capture:
            errors.append(f"{context}: {event_type} pre_capture is not {pre_capture}")
        actual_post = event.get("post_capture")
        if not numeric(actual_post) or actual_post != post_capture:
            errors.append(f"{context}: {event_type} post_capture is not {post_capture}")
    return errors


def validate(config, days, pre_capture, post_capture, camera_names):
    if not isinstance(config, dict):
        return ["Frigate API config must be a JSON object"]
    errors = validate_record(config.get("record"), "global config", days, pre_capture, post_capture)
    cameras = config.get("cameras")
    if not isinstance(cameras, dict):
        return errors + ["Frigate API config cameras section is missing or invalid"]
    for camera_name in camera_names:
        camera = cameras.get(camera_name)
        if not isinstance(camera, dict):
            errors.append(f"camera missing or invalid: {camera_name}")
            continue
        errors.extend(validate_record(camera.get("record"), camera_name, days,
                                      pre_capture, post_capture))
    return errors


def main():
    if len(sys.argv) < 5:
        raise ValueError("usage: validator DAYS PRE_CAPTURE POST_CAPTURE CAMERA [CAMERA ...]")
    try:
        days, pre_capture, post_capture = (int(value) for value in sys.argv[1:4])
    except ValueError as error:
        raise ValueError("expected recording values must be integers") from error
    if days <= 0 or pre_capture < 0 or post_capture < 0:
        raise ValueError("retention days must be positive and capture seconds non-negative")
    config = json.load(sys.stdin)
    errors = validate(config, days, pre_capture, post_capture, sys.argv[4:])
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (json.JSONDecodeError, UnicodeError, ValueError) as error:
        print(f"frigate-event-recording-validation: {error}", file=sys.stderr)
        raise SystemExit(1)
