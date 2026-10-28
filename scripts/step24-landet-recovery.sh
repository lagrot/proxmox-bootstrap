#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo 'Usage: step24-landet-recovery.sh --dry-run | --backup DIRECTORY | --verify DIRECTORY | --restore-test DIRECTORY'; }
mode="${1:-}"; directory="${2:-}"
case "$mode" in
 --dry-run) [[ $# == 1 ]] || { usage >&2; exit 2; };;
 --backup|--verify|--restore-test) [[ $# == 2 && -d "$directory" && ! -L "$directory" ]] || { usage >&2; exit 2; };;
 *) usage >&2; exit 2;;
esac
[[ $EUID == 0 ]] || { echo 'Run as root' >&2; exit 1; }
if [[ "$mode" == --dry-run ]]; then
 echo 'Would snapshot-back up managed CT240 without stopping it, including its rootfs and secrets.'
 echo 'Would include protected host Landet metadata; archives remain root-only.'
 echo 'Restore test uses stopped temporary CT924; never starts it or changes the published route.'
 exit 0
fi
for command in realpath stat find zstd tar python3 sha256sum; do
 command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
directory="$(realpath "$directory")"
[[ $(stat -c %u "$directory") == 0 && $(stat -c %a "$directory") == 700 ]] || { echo 'Backup directory must be root-owned mode 0700' >&2; exit 1; }
if [[ "$mode" != --verify ]]; then
 for command in pct qm pvesm vzdump flock; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
 done
 if [[ "${BACKUP_LOCK_HELD:-0}" != 1 ]]; then
  exec 8>/run/lock/proxmox-bootstrap-backup.lock
  flock -n 8 || { echo 'Another backup/restore is running' >&2; exit 1; }
 fi
 exec 7>/run/lock/proxmox-bootstrap-landet-deploy.lock
 flock -n 7 || { echo 'Another Landet deployment is running' >&2; exit 1; }
fi
if [[ "$mode" == --backup ]]; then
 [[ ! -e "$directory/landet-recovery.json" ]] || { echo 'Landet backup already exists; refusing overwrite' >&2; exit 1; }
 pct config 240 | python3 -c 'import sys,urllib.parse; d=dict(s.rstrip().split(": ",1) for s in sys.stdin if ": " in s); assert d.get("hostname")=="landet-viewer" and d.get("unprivileged")=="1" and urllib.parse.unquote(d.get("description","")).strip()=="Managed Landet viewer - proxmox-bootstrap"'
 [[ $(pct status 240) == 'status: running' ]] || exit 1
 pct exec 240 -- python3 - capture / < "$ROOT/lib/landet_recovery.py" > "$directory/landet-recovery.json"
 tar -czf "$directory/landet-host.tar.gz" -C / var/lib/proxmox-bootstrap/landet
 # Only Proxmox temporary CT metadata needs user-namespace traversal.
 # The archive destination remains root-only throughout.
 backup_work="$(mktemp -d /tmp/landet-vzdump.XXXXXXXX)"
 chmod 0711 "$backup_work"
 trap 'rm -rf -- "$backup_work"' EXIT
 (umask 0022; vzdump 240 --mode snapshot --compress zstd --tmpdir "$backup_work" --dumpdir "$directory" --quiet 1)
 rm -rf -- "$backup_work"
 trap - EXIT
 chmod 600 "$directory/landet-recovery.json" "$directory/landet-host.tar.gz" "$directory"/vzdump-lxc-240-*
 (cd "$directory"; sha256sum -- landet-recovery.json landet-host.tar.gz vzdump-lxc-240-*.tar.zst > landet-SHA256SUMS)
fi
mapfile -t archives < <(find "$directory" -maxdepth 1 -type f -name 'vzdump-lxc-240-*.tar.zst' -size +0c)
[[ ${#archives[@]} == 1 && -s "$directory/landet-recovery.json" && -s "$directory/landet-host.tar.gz" ]] || { echo 'Incomplete CT240 backup' >&2; exit 1; }
archive="${archives[0]}"
(cd "$directory"; sha256sum -c landet-SHA256SUMS >/dev/null)
[[ $(stat -c %a "$archive") == 600 ]] || { echo 'Archive is not mode 0600' >&2; exit 1; }
zstd -t --quiet "$archive"
tar -tzf "$directory/landet-host.tar.gz" >/dev/null
# Check actual archived files, not only the compressor checksum.
work="$(mktemp -d /tmp/landet-recovery.XXXXXXXX)"
restored=0; mounted=0
marker="proxmox-bootstrap-landet-restore-$(date +%s)-$$"
cleanup() {
 local result=$?
 trap - EXIT
 if (( restored )); then
  if [[ $(pct status 924) != 'status: stopped' ]] || ! pct config 924 | grep -Eq "^description: ${marker}(%0A)?$"; then
   echo 'Temporary CT ownership/state changed; refusing cleanup' >&2; result=1
  else
   if (( mounted )); then pct unmount 924 >/dev/null || result=1; mounted=0; fi
   if (( result == 0 )); then pct destroy 924 --purge 1 >/dev/null || result=1; fi
  fi
 fi
 if [[ "$mode" == --restore-test && "$result" == 0 ]]; then
  [[ ! -e /etc/pve/lxc/924.conf ]] || result=1
  if pvesm list local-lvm --vmid 924 | awk 'NR>1{found=1} END{exit !found}'; then
   echo 'Temporary restore volumes remain' >&2; result=1
  fi
  if (( result == 0 )); then
   python3 - "$directory" <<'RECEIPT'
import datetime, json, os, pathlib, sys
path = pathlib.Path('/var/lib/proxmox-bootstrap/landet-recovery-status.json')
value = {'schema_version': 1, 'completed_at': datetime.datetime.now().astimezone().isoformat(),
         'backup_directory': sys.argv[1], 'result': 'stopped-restore-success', 'temporary_ct': 924}
temporary = path.with_suffix('.tmp')
temporary.write_text(json.dumps(value)+'\n')
os.chmod(temporary, 0o600)
temporary.replace(path)
RECEIPT
   result=$?
  fi
 fi
 rm -rf -- "$work"
 exit "$result"
}
trap cleanup EXIT
mkdir "$work/host"
tar -xzf "$directory/landet-host.tar.gz" -C "$work/host"
python3 - "$work/host" <<'HOST_METADATA'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])/'var/lib/proxmox-bootstrap/landet'
for name in ('access.json', 'publication.json'):
    if not isinstance(json.loads((root/name).read_text()), dict):
        raise SystemExit('Invalid host Landet metadata')
HOST_METADATA
if [[ "$mode" == --restore-test ]]; then
 [[ ! -e /etc/pve/lxc/924.conf && ! -e /etc/pve/qemu-server/924.conf ]] || { echo 'Temporary guest 924 already exists' >&2; exit 1; }
 while read -r storage _; do
  [[ "$storage" != Name && -n "$storage" ]] || continue
  if pvesm list "$storage" --vmid 924 | awk 'NR>1{found=1} END{exit !found}'; then
   echo 'Temporary guest 924 has existing volumes' >&2; exit 1
  fi
 done < <(pvesm status --enabled 1)
 (umask 0022; pct restore 924 "$archive" --storage local-lvm --unique 1 --start 0 --onboot 0 --description "$marker")
 restored=1
 [[ $(pct status 924) == 'status: stopped' ]] || exit 1
 pct config 924 | grep -qx 'onboot: 0' || exit 1
 pct set 924 --delete net0 >/dev/null
 pct mount 924 >/dev/null; mounted=1
 python3 "$ROOT/lib/landet_recovery.py" verify /var/lib/lxc/924/rootfs "$directory/landet-recovery.json"
 echo 'Stopped CT924 rootfs restore verified; no application boot or live failover is claimed.'
else
 tar --zstd -xf "$archive" -C "$work" './etc/landet' './etc/nginx' './etc/systemd/system/landet.service' './etc/systemd/system/landet-relay.service' './opt/landet' './var/lib/landet-deploy' './etc/passwd' './etc/group' './etc/apt/apt.conf.d/99-landet-manual-updates'
 python3 "$ROOT/lib/landet_recovery.py" verify "$work" "$directory/landet-recovery.json"
fi
