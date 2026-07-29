# Step 20 - Update Operations

Step 20 has one narrow automation boundary:

- CT 200, CT 210, and CT 220 can install Debian Security updates through one
  controlled script.
- Package installation is manual, one CT at a time, and snapshot protected.
- Independent automatic installation and automatic rebooting are disabled.
- Proxmox and application upgrades are never applied by this workflow.
- Step 12 recovery backups remain a separate operation.

For the condensed SSH runbook, use `UPDATE-QUICK-GUIDE.txt`.

## Normal operation

Run:

```bash
bash scripts/step20-status.sh
```

The status shows:

- the timestamp and package counts from the last weekly audit;
- the latest recovery backup and whether it is current;
- live reboot markers;
- whether the controlled security policy is correctly configured;
- any retained update snapshot and when its cleanup is allowed.

Audit counts can be up to one week old and are labelled accordingly. The
backup line reports the separate Step 12 recovery operation.

## Weekly audit

Run manually when needed:

```bash
bash scripts/step20a-update-audit.sh
```

The installed host timer runs it each Monday after the Sunday backup. It
refreshes APT metadata and records versions, pending packages, Debian Security
packages, reboot markers, and recovery-backup age. It never installs packages
or reboots a system.

Install or refresh the timer:

```bash
bash scripts/step20d-update-audit-schedule.sh
```

Protected runtime files:

- `/var/log/proxmox-bootstrap/update-audit.log`
- `/var/lib/proxmox-bootstrap/update-audit-status.json`

The JSON is machine state. Use `step20-status.sh` for the human view.

## Controlled CT security updates

Run the non-mutating prerequisite and package simulation:

```bash
bash scripts/step20f-unattended-upgrades.sh --dry-run
```

One-time deployment:

```bash
bash scripts/step20f-unattended-upgrades.sh --confirm-install
```

Validate the deployed files, effective APT policy, and timers:

```bash
bash scripts/step20g-unattended-upgrades-validation.sh
```

The policy:

- accepts Debian Security origins only;
- preserves locally modified package configuration;
- refreshes package metadata but does not install packages automatically;
- disables automatic rebooting;
- leaves installation, reboot-required handling, and validation to
  `step20-update-ct.sh`.

The Proxmox host, ordinary Debian updates, third-party Docker packages,
Frigate images, Hermes releases, Home Assistant, and firmware are excluded.
Normal operation for one CT:

```bash
bash scripts/step20-update-ct.sh ct210 --dry-run
bash scripts/step20-update-ct.sh ct210 --confirm
# After at least 24 hours:
bash scripts/step20-update-ct.sh ct210 --cleanup
```

The script checks the live baseline before creating a snapshot. Confirm stops
the CT, creates a consistent snapshot, starts it, validates again, installs
only the simulated Debian Security package set, reboots only when Debian marks
one required, and performs final regression validation. A failure keeps the
snapshot and prints explicit inspection/rollback commands. Rollback is never
automatic.

The first CT 210 pilot, a controlled failure, a real snapshot rollback,
re-patching, and managed cleanup passed. Cleanup revalidated MQTT, deleted only
the recorded snapshot, and removed its protected state. The acceptance test
used an explicit zero-age override; the normal command still enforces the
24-hour observation period.

The CT 220 pilot then installed 21 Debian Security updates with no reboot
required. The Hermes provider smoke test, active gateway, doctor connectivity,
package integrity, and systemd health passed afterward. Managed cleanup
revalidated Hermes and removed only its recorded snapshot and state. This
cleanup also used the explicit zero-age acceptance-test override.

## Failure and rollback

Inspect the exact retained snapshot:

```bash
pct listsnapshot 210
```

If rollback is selected after inspection:

```bash
pct stop 210
pct rollback 210 EXACT_SNAPSHOT_NAME
pct start 210
bash scripts/step20c-post-update-validation.sh ct210
```

`EXACT_SNAPSHOT_NAME` is the `pbsec-...-ct210` name printed by the failed
update and by `pct listsnapshot 210`. Rollback restores the pre-update CT disk,
including its package versions. It does not retry the update.

## Other maintenance

`step20b-update-plan.sh` is review-only. It does not provide generic apply
commands for Proxmox, full CT upgrades, or applications. In particular:

- Step 12 does not contain a Proxmox host backup or complete CT root filesystems.
- Home Assistant updates use its web interface and its own backup.
- Frigate upgrades use `docs/step18-frigate-upgrade.md`.
- Docker, MQTT feature releases, Hermes, and Zigbee firmware need separately
  tested procedures before they can be applied.

After a separately reviewed change, existing regression routing remains
available:

```bash
bash scripts/step20c-post-update-validation.sh TARGET
```

Snapshots are temporary rollback points, not backups. The updater retains a
successful snapshot for at least 24 hours. Cleanup validates the CT again and
deletes only the exact snapshot recorded in protected local state.

## Full validation

```bash
bash scripts/step20e-update-operations-validation.sh
```

This validates the host audit timer and log rotation, protected status files,
the non-mutating setup check, the deployed security policy, and the human
status command. Focused MVP command and failure-path tests are available with:

```bash
bash scripts/step20-update-ct-tests.sh
```

## References

- [Debian unattended-upgrades README](https://sources.debian.org/src/unattended-upgrades/2.13/README.md)
- [Debian unattended-upgrade manual](https://manpages.debian.org/unstable/unattended-upgrades/unattended-upgrade.8.en.html)
- [Proxmox VE administration guide](https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf)
- [Home Assistant OS update tasks](https://www.home-assistant.io/common-tasks/os/)
