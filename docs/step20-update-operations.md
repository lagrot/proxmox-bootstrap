# Step 20 - Update Operations

Step 20 has one narrow automation boundary:

- CT 200, CT 210, and CT 220 can install Debian Security updates through one
  controlled script.
- Package installation is manual, one CT at a time, and rollback protected.
- Independent automatic installation and automatic rebooting are disabled.
- Proxmox and application upgrades are never applied by this workflow.
- Step 12 recovery backups remain a separate operation.

For the condensed SSH runbook, use `UPDATE-QUICK-GUIDE.txt`.

## Target names and package scope

The target selects an LXC and its post-update validation route. It does not
request a generic application or full-system upgrade.

| Target | Eligible update scope | Explicitly excluded |
|---|---|---|
| `ct200` | Installed packages offered by Debian Security; stopped full-rootfs backup protection | Docker Engine/Compose from `download.docker.com`; pinned Frigate image |
| `ct210` | Installed packages offered by Debian Security, including Mosquitto when Debian Security publishes a fix | Ordinary Debian feature updates and generic full upgrades |
| `ct220` | Installed packages offered by Debian Security | Hermes application release |

Mosquitto is eligible in CT 210 because it is installed as a native Debian
package. Docker and Hermes use non-Debian installation sources, while Frigate
is a pinned container image, so those application updates require their own
procedures.

CT 200's `/mnt/frigate` host bind mount makes the LXC snapshot feature
unavailable. The updater instead creates a stopped, compressed `vzdump`
archive of CT 200's complete root filesystem and configuration. The archive
contains `/opt/frigate`, including the Compose file, Frigate configuration,
and database. Proxmox does not include bind-mount contents, so camera media
under `/mnt/frigate` is neither copied nor changed.

CT 210 and CT 220 continue to use stopped, consistent Proxmox snapshots.

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
- any retained update rollback point and when its cleanup is allowed.

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
or reboots a system. Managed CT security counts use the same Debian
`unattended-upgrade` policy engine as the controlled updater; generic
`apt-get` output is not used to infer those counts.

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

The Debian `unattended-upgrades` package is used as the tested security-only
package selection and installation engine. Its automatic installation timer
is disabled, so the operator-controlled script remains the only apply path.
Both dry-run and confirm refresh package metadata before determining whether
security updates exist. If none exist, the command exits before the full
service baseline. While either command runs, it temporarily pauses the
metadata timer to prevent an APT race and restores the timer on exit.

The Proxmox host, ordinary Debian updates, third-party Docker packages,
Frigate images, Hermes releases, Home Assistant, and firmware are excluded.
Normal operation for one CT:

```bash
# Optional preview:
bash scripts/step20-update-ct.sh ct210 --dry-run
# Patch:
bash scripts/step20-update-ct.sh ct210 --confirm
# After at least 24 hours:
bash scripts/step20-update-ct.sh ct210 --cleanup
```

The dry-run is optional. Confirm repeats current metadata refresh, package
discovery, policy checks, storage checks, and the pre-update baseline before
creating rollback protection or installing anything.

The script checks the live baseline before creating rollback protection.
CT 200 gets a stopped full-rootfs backup; CT 210 and CT 220 get stopped,
consistent snapshots. Confirm validates the service again, installs only the
simulated Debian Security package set, reboots only when Debian marks one
required, and performs final regression validation. A failure keeps the
rollback point and prints explicit inspection/rollback commands. Rollback is
never automatic.

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

### CT 200 full-backup restore

The one-time stopped restore drill proves the CT 200 method without starting
the temporary restored container:

```bash
bash scripts/step20i-ct200-restore-test.sh
```

The drill briefly stops CT 200 to create a full archive, restores that archive
to unused temporary CT ID 920, verifies the restored `/opt/frigate` files and
bind-mount configuration, and then destroys the temporary CT and test archive.
The real managed cleanup path is also verified: it revalidated CT 200 and
removed only its recorded backup directory and protected state. Acceptance
used an explicit zero-age override; normal operation still enforces 24 hours.

If a CT 200 update fails, inspect its protected state:

```bash
cat /var/lib/proxmox-bootstrap/security-updates/ct200.state
```

Use the complete value after `backup_archive=` as `CT200_BACKUP`:

```bash
pct stop 200
pct restore 200 CT200_BACKUP --force 1 --storage local-lvm
pct start 200
bash scripts/step20c-post-update-validation.sh ct200
```

The restore replaces CT 200's root filesystem and configuration. It does not
restore, delete, or modify camera media in the host directory `/mnt/frigate`.

## Other maintenance

The controlled CT updater does not provide generic apply commands for Proxmox,
full CT upgrades, or applications. In particular:

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

The CT 210/220 snapshots and CT 200 update archive are temporary rollback
points, not weekly recovery backups. The updater retains a successful rollback
point for at least 24 hours. Cleanup validates the CT again and deletes only
the exact snapshot or archive recorded in protected local state.

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
