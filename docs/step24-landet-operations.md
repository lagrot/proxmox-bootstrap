# CT240 operations and recovery

CT240 `landet-viewer` participates in the existing weekly package audit and
validated recovery backup. Manual Debian Security patching uses `step20-update-ct.sh ct240`.
Automatic installation/reboot and viewer application upgrades remain disabled.

## Operator commands

Run on `nad9-1` from `/root/proxmox-bootstrap`:

```bash
# Read-only workflow preview: no guest calls, locks or output files.
bash scripts/step24-landet-recovery.sh --dry-run

# Refresh APT metadata and report candidates, without installing packages.
bash scripts/step20a-update-audit.sh
bash scripts/step20-status.sh

# Ordinary backup operation, including CT240; existing retention still applies.
# The existing Hermes consistency pause is unchanged.
bash scripts/step12b-backup-operation.sh

# Verify the CT240 portion of the latest successful weekly backup.
backup_dir="$(cat /var/lib/proxmox-bootstrap/backup-last-success)"
bash scripts/step24-landet-recovery.sh --verify "$backup_dir"

# Real rootfs restore into temporary CT924, without ever starting it.
bash scripts/step24-landet-recovery.sh --restore-test "$backup_dir"

# Validate the production application and protected publication afterwards.
bash scripts/step22d-landet-deploy.sh --validate
bash scripts/step22d-landet-publish.sh --validate
```

`--backup DIRECTORY` can also create the CT240 portion alone in an existing,
root-owned mode-0700 directory. It refuses to overwrite an existing Landet
manifest. Each ordinary backup creates a new generation; repeating verification
or the stopped restore test does not modify production. Invalid arguments fail
before creating locks or changing guests. `--verify` creates only a temporary
root-private extraction directory and removes it on exit.

## Coverage and protection

A native snapshot-mode `vzdump` captures CT240's full rootfs and LXC
configuration without stopping its services. This includes `/etc/landet`
(HA credentials, camera relay credentials and Access settings), nginx,
systemd units, service accounts, all installed releases and go2rtc, APT policy,
and prior application rollback state in `/var/lib/landet-deploy`.
The existing host Landet Access/publication metadata is archived separately.
No camera recording archive is duplicated; retained recordings remain in
Frigate. Backups contain secrets: directories stay root-owned 0700, output
files 0600, and no contents belong in Git or chat.

A separate traversable temporary directory lets Proxmox's unprivileged backup
worker read temporary CT metadata without opening the secret backup directory.
The Landet deploy lock prevents configuration/release changes during capture;
the existing backup lock serializes backup and restore operations.
Checksums cover the full CT archive, host metadata and the private fingerprint
manifest. Verification checks zstd integrity, host tar readability and actual
extracted configuration/release hashes, symlink targets and permissions.
Legacy validated backups remain readable but are explicitly reported as lacking
CT240; they do not provide Landet coverage.

The audit and updater use the same Debian Security-only unattended-upgrades
simulation for all five CT targets. CT240 policy setup, manual patch preview,
confirmation and cleanup follow `UPDATE-QUICK-GUIDE.txt`. A patch with pending
updates stops the CT for its snapshot, installs eligible Debian packages and
validates both upstream data and public Access protection. Viewer releases and
the copied go2rtc binary remain separate application maintenance.

```bash
bash scripts/step20-update-ct.sh ct240 --dry-run
# During a maintenance window, after reviewing the preview:
bash scripts/step20-update-ct.sh ct240 --confirm
# After at least 24 hours of healthy operation:
bash scripts/step20-update-ct.sh ct240 --cleanup
```

## Restore proof and limits

The drill refuses an occupied CT924 ID, including leftover storage volumes.
It restores with `--start 0 --onboot 0`, removes its network configuration,
mounts the stopped filesystem, and compares configuration/secrets/releases and
permissions with the captured manifest. Cleanup destroys only a stopped guest
with this run's ownership marker. A failed/partial restore may be retained for
inspection; do not remove a guest without checking its identity.

The CT240 pilot and the full ordinary weekly backup passed, including archive
extraction and checksum validation. A real stopped CT924 restore passed with
matching files/permissions; CT924 was removed and production stayed running.
A root-only successful-drill receipt is shown by `step20-status.sh`.
Nine isolated recovery/audit tests cover file changes, missing units/releases,
secret modes, non-mutating preview, invalid arguments and audit success/refresh
failure. Eighteen isolated updater workflow tests cover the new CT targets,
installation ordering, no-update exits, failure retention and cleanup.
Operator checks also rejected a corrupt backup checksum and a non-private
backup directory. Production source/access and external publication validators
passed after the pilot.

This proves archive/rootfs restoration, not a booted replacement, end-to-end
failover, host disaster recovery or Cloudflare control-plane restoration.
Before a real recovery, isolate the failed original, restore to the intended
ID/storage, verify network identity and origin restrictions, then validate
Access enforcement and both upstream sources before serving traffic.

Backups remain on the same Proxmox host. Encrypted off-host copies and a
separately rehearsed replacement-host recovery are still needed for host/disk
loss. Do not delete the retained pre-OS-baseline snapshot as part of this work.

## Proxmox host patching

Patch regularly in a planned maintenance window; guest backups and snapshots
do not undo host kernel, bootloader or networking changes. Proxmox documents
using `apt update` followed by `apt full-upgrade` for its rolling package set;
review the proposed transaction first. These are host maintenance commands,
not part of CT240 auditing or recovery.

For this single-node installation, prefer onsite access or tested independent
console access (for example IPMI, AMT or PiKVM) for host updates/reboots. Do not
defer security fixes for months solely because the next onsite visit is distant;
assess advisories and prepare a controlled remote maintenance window, with a
local helper or independent rescue access where possible. Tailscale/SSH and the
Cloudflare connector all depend on this host; an SSH tunnel is not independent
rescue access. `tmux` protects against a disconnected terminal, not failed boot.
Critical security advisories may justify an earlier window, with a deliberate
recovery arrangement. Check fresh package metadata and relevant advisories
before deciding urgency; cached candidate versions alone do not establish it.

References: [Proxmox software update guidance](https://github.com/proxmox/pve-docs/blob/master/system-software-updates.adoc)
and [Proxmox VE administration guide](https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf).
