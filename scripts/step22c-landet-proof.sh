#!/usr/bin/env bash
# Compatibility entry point; the full viewer supersedes the one-camera pilot.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$ROOT/scripts/step22c-landet-viewer.sh" "$@"
