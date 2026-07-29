# Step 20 - Update Operations

Step 20 provides update visibility and controlled maintenance boundaries
without enabling unattended upgrades or automatic Proxmox-host reboots.

## Policy

- Run a read-only update audit every Monday after the Sunday backup.
- Refresh package metadata, but never install packages from the timer.
- Report Debian security-repository packages separately from other APT
  updates.
- Treat third-party security advisories as a release-note review task; APT
  cannot classify every Docker, Home Assistant, Frigate, Hermes, or firmware
  CVE.
- Update one layer at a time, verify a recent validated backup first, and run
  the matching regression suite afterward.
- Keep Frigate pinned and use Steps 18A-18D for image upgrades.
- Use the Home Assistant UI for Core, Supervisor, OS, integration, and app
  updates.
- Never update Zigbee coordinator firmware merely because a newer build
  exists.
- Treat Step 12 as the durable backup system. Step 20 snapshots are temporary
  VMware-style pre-patch rollback points, not backups.

## Weekly audit

Run manually:

```bash
bash scripts/step20a-update-audit.sh
```

The audit records:

- Proxmox, kernel, Docker, Compose, Frigate, Mosquitto, Hermes, Home Assistant,
  and Zigbee coordinator identity/revision information;
- pending APT updates on the host and CTs 200, 210, and 220;
- packages supplied by the Debian security repository;
- host and container reboot markers;
- whether the latest validated backup is no more than eight days old.

ZHA does not expose the ZBDongle-P radio firmware through the standard HAOS
hardware API. The audit reports the stable identity and USB bridge revision
and marks the radio firmware as unavailable rather than inventing a version.

Protected runtime output:

- log: `/var/log/proxmox-bootstrap/update-audit.log`, mode `0640`;
- status: `/var/lib/proxmox-bootstrap/update-audit-status.json`, mode `0600`.

The log rotates weekly, is compressed after the first rotation, and is kept
for 52 weeks. Logs and status files are runtime data and must not be committed.
The JSON status is the machine-readable automation interface. For the normal
human-readable view, use:

```bash
bash scripts/step20-status.sh
```

This summarizes backup readiness, update and security counts, reboot markers,
managed snapshots, timers, the latest maintenance transaction, and the
recommended next command.

## Schedule

Install and verify the timer:

```bash
bash scripts/step20d-update-audit-schedule.sh
bash scripts/step20e-update-operations-validation.sh
```

The persistent timer runs each Monday at 06:00 Europe/Stockholm with up to ten
minutes of randomized delay. It reports only; it cannot update or reboot a
system.

## Controlled maintenance

Generate the commands for one target:

```bash
bash scripts/step20b-update-plan.sh TARGET
```

Supported targets are `proxmox`, `ct200`, `docker`, `ct210`, `mqtt`, `ct220`,
`hermes`, `homeassistant`, `frigate`, and `zigbee`. The planner refuses to
continue without a successful update audit and a validated backup no more than
eight days old. It only prints commands; the operator must review and run them.

After updating one layer, run:

```bash
bash scripts/step20c-post-update-validation.sh TARGET
```

The target selects existing host, service, hardware, MQTT, Home Assistant,
Frigate, Hermes, and Zigbee validation scripts. An activity-dependent camera
event warning is acceptable when nobody moves in front of a camera; failed
tracks are not.

## Automated Debian CT patching

Steps 20F-20G automate stable Debian package maintenance only for CT 200, CT
210, and CT 220. They do not update the Proxmox host, Home Assistant, Frigate
images, Hermes application releases, Docker major versions, or Zigbee
firmware.

Always start with a dry run:

```bash
bash scripts/step20f-update-target.sh ct210 --dry-run
```

Targets are case-insensitive. A dry run refreshes the target's APT metadata,
verifies the latest Step 12 backup and snapshot capacity, records the proposed
package transaction, and changes no snapshot, installed package, service, or
guest power state.

Apply one target:

```bash
bash scripts/step20f-update-target.sh ct210 --confirm-update
```

The executor:

1. requires a validated Step 12 backup no older than eight days;
2. refuses to run alongside backup/restore or another maintenance operation;
3. requires `local-lvm` usage below 80 percent and fewer than two managed
   maintenance snapshots for the target;
4. stops the CT and creates a `pbupd-*` pre-update snapshot;
5. restarts the unchanged CT and runs its baseline regression;
6. installs all pending packages from its configured stable repositories,
   preserving local configuration files;
7. records `.dpkg-dist` or `.dpkg-new` files for operator review;
8. reboots the CT when `/var/run/reboot-required` exists;
9. runs the target regression suite and a final audit.

Any failure stops the transaction. The snapshot and protected transaction
record remain for diagnosis; rollback never runs automatically. Successful
managed snapshots become eligible for cleanup after seven days. Cleanup
requires a matching successful transaction record and never touches manual
snapshots. Failed and rolled-back transaction snapshots remain until manually
resolved.

Protected output:

- log: `/var/log/proxmox-bootstrap/update-maintenance.log`, mode `0640`;
- transactions: `/var/lib/proxmox-bootstrap/update-transactions`, mode `0700`,
  with root-only status and package records.

Inspect a rollback first:

```bash
bash scripts/step20g-update-rollback.sh \
  --transaction YYYYMMDD-HHMMSS-ct210 \
  --dry-run
```

Perform it only after reviewing the failed transaction:

```bash
bash scripts/step20g-update-rollback.sh \
  --transaction YYYYMMDD-HHMMSS-ct210 \
  --confirm-rollback
```

Rollback discards root-disk changes made after the snapshot, starts the CT,
and runs its regression suite. CT 200's `/mnt/frigate` bind mount is outside
snapshot scope and is not rolled back.

## Initial verified audit

The initial refreshed audit on 2026-07-29 found:

| Scope | Pending packages | Debian security packages |
|---|---:|---:|
| Proxmox host | 0 | 0 |
| CT 200 | 88 | 17 |
| CT 210 | 64 | 16 |
| CT 220 | 66 | 17 |

No packages were installed. The host and all three CTs had no reboot marker,
and the latest validated backup was within the eight-day maintenance gate.
These counts are transient operational state; use the latest protected audit
rather than treating this table as current forever.

## References

- [Proxmox VE administration guide](https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf)
- [Home Assistant OS update tasks](https://www.home-assistant.io/common-tasks/os/)
- [Docker Engine on Debian](https://docs.docker.com/engine/install/debian/)
- [Debian security information](https://www.debian.org/security/)
