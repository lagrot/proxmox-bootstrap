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

## Create A Backup

Run as root on the Proxmox host:

```bash
bash scripts/step12-backup.sh
```

Each successful run has a timestamped directory and `SHA256SUMS`. Incomplete
runs are removed automatically. The default retention is seven completed runs.

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

## Security And Follow-Up

The Mosquitto and Hermes archives contain credentials. The backup root must
remain owned by root with mode `0700`; archive files use mode `0600`. These
backups are not encrypted. An encrypted off-host copy and live restore drills
are later improvements.
