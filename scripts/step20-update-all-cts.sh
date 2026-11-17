#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UPDATER="${SCRIPT_DIR}/step20-update-ct.sh"
targets=(ct210 ct220 ct200 ct240 ct230)

usage() {
  cat <<'EOF'
Usage: bash scripts/step20-update-all-cts.sh (--dry-run | --confirm)

  --dry-run  Show the sequence without changing state or refreshing metadata.
  --confirm  Update eligible Debian Security packages one container at a time.

Stops on the first failure. Existing rollback protection is retained; cleanup
remains a separate operation after observation. CT230 interrupts public routes.
EOF
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
case "$1" in
  --help|-h) usage; exit 0 ;;
  --dry-run|--confirm) mode="$1" ;;
  *) usage >&2; exit 2 ;;
esac

if [[ "$mode" == --dry-run ]]; then
  printf 'Order: %s\n' "${targets[*]}"
  printf '%s\n' 'Each target uses step20-update-ct.sh --confirm, including its own protection and validation.'
  printf '%s\n' 'No package metadata was refreshed; pending updates are discovered during confirmation.'
  exit 0
fi

[[ "$EUID" -eq 0 ]] || { echo 'ERROR: Run as root' >&2; exit 1; }
[[ -f "$UPDATER" ]] || { echo 'ERROR: Per-container updater is missing' >&2; exit 1; }
command -v flock >/dev/null || { echo 'ERROR: flock is missing' >&2; exit 1; }
exec 9>/run/lock/proxmox-bootstrap-update-all.lock
flock -n 9 || { echo 'ERROR: Another all-container update is running' >&2; exit 1; }

completed=()
for target in "${targets[@]}"; do
  printf '\n=== Updating %s ===\n' "$target"
  if bash "$UPDATER" "$target" --confirm; then
    completed+=("$target")
  else
    rc=$?
    printf '\nERROR: %s failed (exit %s). Stopping; later containers were not attempted.\n' "$target" "$rc" >&2
    printf 'Completed targets: %s\n' "${completed[*]:-none}" >&2
    echo 'Inspect the updater output and retained protection before retrying.' >&2
    exit "$rc"
  fi
done
printf '\nAll targets completed: %s\n' "${completed[*]}"
echo 'Rollback protection remains in place. Check: bash scripts/step20-status.sh'
