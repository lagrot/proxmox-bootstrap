#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# == 1 ]] || { echo 'Usage: step22d-landet-access.sh --dry-run | --apply'; exit 2; }
case "$1" in --dry-run|--apply) ;; --help) echo 'Prepare only a separate owner-only Access app; no DNS or tunnel changes.'; exit 0;; *) exit 2;; esac
source "$ROOT/config/defaults.conf"
source "$ROOT/config/local.conf"
export CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN
exec python3 "$ROOT/lib/landet_access_setup.py" "$1"
