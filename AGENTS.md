# AGENTS.md

## Project

This repository is a modular Bash bootstrap and validation framework for the
`nad9-1` Proxmox VE homelab. Read `README.md` and `docs/project-plan.md` for
the authoritative project context and durable decisions.

## Architecture

| Guest | Purpose | Address |
|---|---|---|
| Proxmox host `nad9-1` | Hypervisor | `192.168.8.10` / Tailscale `100.66.43.1` |
| VM 100 | Home Assistant OS | `192.168.8.105:8123` |
| CT 200 | Docker Compose and Frigate | `192.168.8.104:8971` |
| CT 210 | Native Mosquitto MQTT broker | `192.168.8.103:1883` |
| CT 220 | Hermes Agent gateway and Slack bot | `192.168.8.102` |

Frigate uses the dedicated `/mnt/frigate` SATA SSD, Intel iGPU decoding, and a
USB Coral TPU. Hermes runs as the unprivileged `hermes` user with a system-wide
`hermes-gateway.service`; Slack mentions using `@nad9hermes` are the primary
working interface. The Hermes Web UI is optional and must not be exposed to the
public internet.

## Working rules

- Work one step at a time and preserve the simple architecture.
- Prefer readable, safe, idempotent Bash scripts.
- Add or use validation scripts after deployment changes.
- Use Proxmox-native commands: `pct`, `qm`, and the Web UI.
- Prefer `pct enter` and `pct exec` over installing SSH in LXCs.
- Never commit secrets, API keys, tokens, `.env` files, logs, backups, or runtime data.
- Do not expose Proxmox, Home Assistant, Frigate, MQTT, or Hermes directly to the internet; use Tailscale for remote access.
- Treat `old/` as historical reference only; it is not part of the active workflow.
- Do not modify unrelated user changes in a dirty worktree.

## Current priority

The next project work is Home Assistant + MQTT + Frigate integration:

1. Confirm the Home Assistant MQTT integration (`Step 10C` is pending operator confirmation).
2. Add one test camera to Frigate.
3. Validate live view, recording, detection, and MQTT events.
4. Add the Frigate integration in Home Assistant.
5. Confirm camera entities appear in Home Assistant.

Do not add more platform components until one camera is visible in Home
Assistant through Frigate.

## Repository layout

- `config/`: shared defaults
- `docs/`: project plan and manual setup notes
- `lib/`: shared Bash helpers
- `scripts/`: deployment and validation steps
- `logs/`: local runtime logs; do not commit
- `old/`: legacy scripts; reference only

## Common commands

```bash
# Validate Bash syntax
bash -n scripts/<script-name>.sh

# List guests
pct list
qm list

# Enter a container
pct enter 220

# Execute inside a container
pct exec 220 -- systemctl status hermes-gateway.service --no-pager
```

When changing runtime IP handling, prefer discovering addresses from Proxmox
guest/container state. DHCP reservations currently preserve the documented LAN
addresses, but scripts should avoid hardcoding them where practical.

## Documentation convention

Keep `README.md` concise and keep durable architecture, decisions, verified
milestones, and next work in `docs/project-plan.md`. Do not put transient chat
context, Git status, credentials, or runtime logs in project documentation.
