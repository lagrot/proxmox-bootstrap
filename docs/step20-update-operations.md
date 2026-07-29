# Step 20 - Update Operations

Step 20 has one narrow automation boundary:

- CT 200, CT 210, and CT 220 install Debian Security updates automatically.
- Proxmox and application upgrades are never applied by Step 20.
- Step 12 recovery backups are reported for visibility but do not gate the
  standard Debian automatic-update timers.

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
- whether automatic security updates are correctly configured;
- each CT's last recorded automatic-update result and next run.

Audit counts can be up to one week old and are labelled accordingly. A current
recovery backup does not prevent or authorize an automatic security update.

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

## Automatic CT security updates

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
- uses Debian's standard randomized APT timers and logs;
- uses minimal upgrade steps;
- reboots an affected CT when Debian creates `/var/run/reboot-required`.

The Proxmox host, ordinary Debian updates, third-party Docker packages,
Frigate images, Hermes releases, Home Assistant, and firmware are excluded.
The timers operate independently of Step 12 backup state.

Troubleshoot a CT with:

```bash
pct exec CTID -- journalctl \
  -u apt-daily-upgrade.service --since "7 days ago" --no-pager
pct exec CTID -- tail -n 100 \
  /var/log/unattended-upgrades/unattended-upgrades.log
```

After the first run under the deployed policy, confirm `step20-status.sh`
reports `last=success` for all three CTs. Then perform the existing CT 210,
CT 220, and CT 200 regression routes once. This is initial acceptance testing,
not a weekly operator task.

```bash
bash scripts/step20c-post-update-validation.sh ct210
bash scripts/step20c-post-update-validation.sh ct220
bash scripts/step20c-post-update-validation.sh ct200
```

## Deliberate maintenance

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

Snapshots are temporary rollback points for selected high-risk work. They are
not backups and are not part of routine automatic security patching.

## Full validation

```bash
bash scripts/step20e-update-operations-validation.sh
```

This validates the host audit timer and log rotation, protected status files,
the non-mutating setup check, the deployed security policy, and the human
status command.

## References

- [Debian unattended-upgrades README](https://sources.debian.org/src/unattended-upgrades/2.13/README.md)
- [Debian unattended-upgrade manual](https://manpages.debian.org/unstable/unattended-upgrades/unattended-upgrade.8.en.html)
- [Proxmox VE administration guide](https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf)
- [Home Assistant OS update tasks](https://www.home-assistant.io/common-tasks/os/)
