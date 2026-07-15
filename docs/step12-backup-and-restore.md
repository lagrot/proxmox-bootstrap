# Step 12: Local Backup And Restore Validation

Step 12 creates host-local recovery archives for the current homelab services.
The initial implementation stores backups under
`/var/lib/vz/dump/homelab-backups` with root-only permissions.

## Scope

- Home Assistant VM 100: full Proxmox `vzdump` snapshot archive.
- Frigate CT 200: Docker Compose and Frigate configuration; media is excluded.
- Mosquitto CT 210: `/etc/mosquitto`, including its password database.
- Hermes CT 220: application, user state, and gateway systemd unit.

Hermes is briefly stopped while its archive is created so its SQLite state is
consistent. The script restarts it on success or failure.

## Manual Backup And Validation

Run as root on the Proxmox host:

```bash
bash scripts/step12-backup.sh
```

Each archive run has a timestamped directory and `SHA256SUMS`. Incomplete runs
are removed automatically. A backup is not eligible for retention accounting
until validation creates its `.validated` marker.

## Validate And Test Extraction

Validate the newest completed backup:

```bash
bash scripts/step12-backup-validation.sh
```

Or pass a specific backup directory:

```bash
bash scripts/step12-backup-validation.sh \
  /var/lib/vz/dump/homelab-backups/YYYYMMDD-HHMMSS
```

Validation checks every checksum, tests each tar archive, extracts service
archives into a temporary directory, and confirms that a non-empty Home
Assistant `vzdump` archive exists. It does not alter any live guest or service.

## Scheduled Validated Backup

Install the systemd service, timer, and logrotate policy:

```bash
bash scripts/step12c-backup-schedule.sh
```

The timer runs each Sunday at 03:00 Europe/Stockholm with a randomized delay of
up to ten minutes. `Persistent=true` causes a missed run to execute after the
host starts. The operation performs these stages under a shared lock:

1. Check available space against the latest validated backup estimate.
2. Create the Home Assistant and service archives.
3. Verify checksums and extract the service archives into a temporary path.
4. Mark the new backup validated.
5. Retain the newest eight validated weekly backups.
6. Atomically update the latest status JSON.

The capacity guard requires the estimated archive size plus 25 percent
headroom and preserves at least 20 percent free space. It fails without
removing a valid backup when those conditions cannot be met.

Run the same operation manually through systemd:

```bash
systemctl start proxmox-bootstrap-backup.service
```

## Status And Logs

```bash
systemctl status proxmox-bootstrap-backup.service --no-pager
systemctl list-timers proxmox-bootstrap-backup.timer --all --no-pager
journalctl -u proxmox-bootstrap-backup.service --since today --no-pager
python3 -m json.tool /var/lib/proxmox-bootstrap/backup-status.json
```

The protected file log is `/var/log/proxmox-bootstrap/backup.log`. It is
rotated weekly, compressed, and retained for 52 rotations. Runtime logs and
status files must not be committed.

Validate the installed operational files:

```bash
bash scripts/step12d-backup-operations-validation.sh
```

## Home Assistant Restore Drill

Run the non-disruptive restore drill:

```bash
bash scripts/step12e-homeassistant-restore-drill.sh
```

The drill requires VM ID 900 to be completely unused. It validates the newest
backup, restores Home Assistant with a unique network identity, keeps the VM
stopped, disables `onboot`, and verifies its configuration and referenced
disks. Cleanup is allowed only while the VM is stopped and has the drill's
unique ownership marker. The verified temporary VM and its volumes are then
removed. The drill never starts the restored guest.

## Security And Follow-Up

The Mosquitto and Hermes archives contain credentials. The backup root must
remain owned by root with mode `0700`; archive files use mode `0600`. These
backups are not encrypted. An encrypted off-host copy and a separately planned
live guest boot/application restore test are later improvements.
