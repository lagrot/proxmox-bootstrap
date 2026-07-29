# Step 20 - Update Operations

Step 20 provides update visibility and controlled maintenance boundaries
without enabling unattended upgrades or automatic reboots.

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
