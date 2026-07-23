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

The Home Assistant + MQTT + Frigate baseline is complete through Step 10N.
MQTT authentication, weekly validated local backups, protected backup logging,
and the stopped Home Assistant restore drill are verified.

The Tapo C320WS is verified as the second Frigate camera without breaking the
Tapo C200 baseline. Both cameras are recording in Frigate and Home Assistant;
camera-specific streams, recordings, person detection, snapshots, clips,
MQTT, Intel VAAPI, and Coral detection are verified. The native Home Assistant
dashboard is also verified with separate Live, Review, and System views for
both cameras. Event-only recording is verified: idle and motion-only video is
not retained, while person alert/detection video is retained for ten days.
Step 13 snapshot and export retention is verified: snapshots inherit one
global ten-day policy, exports are never deleted automatically, and the audit
reports export age plus dedicated SSD capacity.
Step 14A face-recognition readiness is also complete and read-only. Native
recognition remains disabled. Hardware requirements pass, but both 640x360
detect streams carry a face-detail warning; any Step 14B pilot must start with
one camera and the CPU-oriented small model.
Steps 18A-18D now provide the controlled stable Frigate upgrade workflow.
Preflight, dry-run, baseline regression, and temporary restore tests pass, but
no production upgrade or rollback has occurred. Frigate remains pinned to
0.17.2; never use the workflow with beta, RC, development, `stable`, or
`latest` targets.
Steps 19A-19B pass the Sonoff ZBDongle-P through to HAOS VM 100 and verify its
stable serial identity, loaded ZHA integration, healthy Home Assistant, and
unchanged Coral access. The first end device, a THIRDREALITY `3RTHS24BZ`
temperature and humidity sensor, is paired and reporting temperature, humidity,
and battery states.
Continue with:

1. Decide whether to proceed with a one-camera face-recognition pilot, select
   the camera based on final placement and privacy, and define acceptance
   criteria before deployment.
2. Design camera notifications without creating excessive alerts.
3. Research Hermes Agent integration with Home Assistant and decide whether
   CT 220 should remain the isolated Hermes gateway.
4. Configure zones, masks, and detection tuning after camera placement is
   final.
5. Let the first Zigbee sensor establish a stable baseline before considering
   its available firmware update or adding sensor-driven automations.

Keep both verified camera baselines working while making these changes.

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
