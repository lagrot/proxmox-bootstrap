# Step 20 - Update Operations

Step 20 keeps routine security maintenance simple:

- Step 12 creates and validates the weekly recovery backup.
- Debian installs security updates automatically in CT 200, CT 210, and CT
  220.
- The Proxmox host and application releases remain deliberate maintenance.
- The weekly audit and `step20-status.sh` provide visibility.

## Human status

Use this as the normal operator interface:

```bash
bash scripts/step20-status.sh
```

The protected JSON under `/var/lib/proxmox-bootstrap` is machine-readable
state, not the primary human interface.

## Weekly audit

Run manually when needed:

```bash
bash scripts/step20a-update-audit.sh
```

The installed systemd timer runs the same read-only audit each Monday after
the Sunday backup. It records versions, pending updates, Debian security
updates, reboot markers, and backup readiness.

Install or refresh the audit timer:

```bash
bash scripts/step20d-update-audit-schedule.sh
```

## Automatic CT security updates

Review the one-time setup:

```bash
bash scripts/step20f-unattended-upgrades.sh --dry-run
```

Enable it:

```bash
bash scripts/step20f-unattended-upgrades.sh --confirm-install
```

The script installs Debian's `unattended-upgrades` package in CT 210, CT 220,
and CT 200. The deployed policy:

- checks daily using Debian's standard APT systemd timers;
- accepts packages from Debian Security only;
- preserves locally modified package configuration;
- uses minimal upgrade steps;
- reboots a CT only when `/var/run/reboot-required` exists;
- uses Debian's standard logs under `/var/log/unattended-upgrades/`.

It does not configure unattended upgrades on the Proxmox host and cannot
upgrade Docker's third-party repository, Frigate images, Hermes application
releases, Home Assistant, or Zigbee firmware.

Validate the one-time setup:

```bash
bash scripts/step20g-unattended-upgrades-validation.sh
```

Debian's own non-mutating diagnostic is available inside any CT:

```bash
pct exec 210 -- unattended-upgrade --dry-run --debug
```

## Deliberate maintenance

Review these approximately monthly:

- Proxmox host packages and host reboot requirements;
- ordinary non-security Debian updates;
- Home Assistant Core, Supervisor, OS, integrations, and apps;
- Docker, Frigate, Hermes, and firmware release notes.

Use `step20b-update-plan.sh` only to print commands for these deliberate
layers. Use `step20c-post-update-validation.sh TARGET` after a deliberate
change.

Snapshots are reserved for major or high-risk changes such as release
upgrades, storage changes, and application migrations. They are not part of
routine Debian security patching. Step 12 remains the authoritative backup and
restore workstream.

## References

- [Debian unattended-upgrades README](https://sources.debian.org/src/unattended-upgrades/2.13/README.md)
- [Debian unattended-upgrade manual](https://manpages.debian.org/unstable/unattended-upgrades/unattended-upgrade.8.en.html)
- [Proxmox VE administration guide](https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf)
- [Home Assistant OS update tasks](https://www.home-assistant.io/common-tasks/os/)
- [Docker Engine on Debian](https://docs.docker.com/engine/install/debian/)
