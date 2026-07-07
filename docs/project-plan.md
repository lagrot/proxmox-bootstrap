# Proxmox Homelab Project Plan

This document records the current project state and near-term plan for the `nad9-1` Proxmox homelab bootstrap.

It is meant to be durable project documentation. It should stay focused on the current architecture, verified decisions, and next useful work. Avoid storing transient chat context, Git status snippets, API keys, secrets, or runtime logs here.

## Working Principles

- Build one step at a time.
- Keep Bash scripts readable, safe, and idempotent where practical.
- Prefer validation scripts after deployment scripts.
- Use Proxmox-native administration with `pct`, `qm`, and the Web UI.
- Use `pct enter` and `pct exec` instead of installing SSH into every LXC.
- Keep secrets, API keys, tokens, `.env` files, logs, and runtime data out of Git.
- Keep the setup simple unless there is evidence that more complexity is needed.
- During troubleshooting, prefer one command at a time.

## Host And Hardware

| Item | Value |
|---|---|
| Hostname | `nad9-1` |
| Proxmox IP | `192.168.0.223` |
| Proxmox VE | `9.2.3` |
| Kernel observed | `7.0.14-3-pve` |
| Hardware | Minisforum NAD9 |
| CPU | 12th Gen Intel Core i9-12900H |
| GPU | Intel iGPU |
| RAM | Initially 16 GiB |
| System storage | 512 GB NVMe for Proxmox / VM / LXC storage |
| Media storage | 512 GB SATA SSD dedicated to Frigate media |
| Accelerator | USB Coral TPU |

Current Stockholm/fiber speed test observed:

| Direction | Result |
|---|---:|
| Download | 865.64 Mbit/s |
| Upload | 545.52 Mbit/s |
| Ping | 9.7 ms |

Future location note: this server may later move behind a 4G/5G router at the country house. Do not expose Proxmox, Home Assistant, Frigate, MQTT, Hermes, or the Hermes Web UI directly to the internet. Use VPN or a secure tunnel for remote access.

## Current Architecture

```text
Proxmox Host nad9-1
IP: 192.168.0.223

├── VM 100: Home Assistant OS
│     └── Home Assistant Core / Supervisor
│
├── CT 200: docker-core / frigate-core
│     └── Docker Compose
│           └── Frigate
│                 ├── Intel iGPU decode acceleration
│                 ├── USB Coral TPU object detection
│                 └── /mnt/frigate recordings/snapshots/exports
│
├── CT 210: mqtt-core
│     └── Mosquitto MQTT native Debian package
│
└── CT 220: hermes-agent
      └── Hermes Agent gateway / optional Web UI
```

Current addresses:

| Service | Location | Address |
|---|---|---|
| Proxmox | host | `https://192.168.0.223:8006` |
| Home Assistant | VM 100 | `http://192.168.0.218:8123` |
| Frigate | CT 200 | `https://192.168.0.224:8971` |
| MQTT / Mosquitto | CT 210 | `192.168.0.217:1883` |
| Hermes Agent | CT 220 | `192.168.0.225` |
| Hermes Web UI | CT 220 | `http://192.168.0.225:9119` |
| Slack bot | Slack | `nad9hermes` |

## Repository Layout

```text
config/
  defaults.conf

docs/
  Project documentation and manual setup notes

lib/
  Shared Bash framework helpers

logs/
  Local runtime logs, not committed

old/
  Legacy scripts kept for reference, not part of the active workflow

scripts/
  Deployment and validation steps
```

Legacy scripts currently kept in `old/`:

- `old/setup-frigate-disk.sh`
- `old/step1-host-validation.sh`

## Frigate Storage

The SATA SSD is prepared for Frigate media.

| Item | Value |
|---|---|
| Disk | `/dev/sda` |
| Partition | `/dev/sda1` |
| Stable path | `/dev/disk/by-id/ata-PNY_500GB_SATA_SSD_PNH05266000310302979-part1` |
| Filesystem | XFS |
| Label | `frigate_data` |
| UUID | `d70d9c1d-a67d-4540-88d8-e6e4fcbf5e9a` |
| Mountpoint | `/mnt/frigate` |
| Mount options | `noatime,inode64,logbufs=8,logbsize=262144` |

Expected media directories:

- `/mnt/frigate/clips`
- `/mnt/frigate/clips/thumbs`
- `/mnt/frigate/recordings`
- `/mnt/frigate/snapshots`
- `/mnt/frigate/exports`

Because CT 200 is unprivileged and uses a bind mount, the host-side ownership is:

```bash
chown -R 100000:100000 /mnt/frigate
chmod -R 775 /mnt/frigate
```

## Verified Steps

| Step | Description | Status |
|---|---|---|
| Step 01 | Host validation | verified |
| Step 02 | Frigate storage | verified |
| Step 03 | Docker LXC foundation | verified |
| Step 03B | Docker bootstrap in CT 200 | verified |
| Step 03C | Hardware passthrough | verified |
| Step 04 | Frigate deployment | verified |
| Step 04B | Frigate validation | verified |
| Step 05 | MQTT LXC deployment | verified |
| Step 05B | MQTT validation | verified |
| Step 06 | Home Assistant OS VM | verified |
| Step 06B | Home Assistant validation | verified |
| Step 07A | Home Assistant initial setup checklist | documentation |
| Step 07B | Frigate / MQTT / Home Assistant integration notes | documentation |
| Step 08 | Hermes Agent LXC base | verified |
| Step 08B | Hermes LXC validation | verified |
| Step 08C | Hermes bootstrap | verified |
| Step 08D | Hermes bootstrap validation | verified |
| Step 08E | Hermes provider / API config | verified |
| Step 08F | Hermes gateway service validation | verified |
| Step 09A | Hermes Slack mention integration | verified |
| Step 09B | Hermes dashboard service | verified |
| Step 09C | Hermes dashboard validation | verified |
| Step 10A | Home Assistant reachability | verified |
| Step 10B | Home Assistant to MQTT network path | verified |
| Step 10C | Home Assistant MQTT integration | needs operator confirmation |
| Step 10D | Frigate MQTT config | verified |
| Step 10E | Frigate restart | verified |
| Step 10F | Frigate MQTT publishing | verified |

## Service Decisions

- Home Assistant stays as HAOS VM 100.
- Mosquitto is external in CT 210, not a Home Assistant add-on.
- Frigate is external in CT 200 with Docker Compose, not a Home Assistant add-on.
- Hermes is isolated in CT 220.
- CT 200 is Frigate / Docker only.
- CT 210 is MQTT only.
- CT 220 is Hermes only.
- Frigate MQTT remains disabled until the Home Assistant / MQTT / Frigate integration step.
- Do not add duplicate Mosquitto or Frigate add-ons inside Home Assistant.

## Current Services

### CT 200 - Frigate

Frigate runs in CT 200 through Docker Compose.

| Item | Value |
|---|---|
| CT ID | `200` |
| Hostname | `docker-core` |
| IP | `192.168.0.224` |
| Image | `ghcr.io/blakeblackshear/frigate:stable` |
| URL | `https://192.168.0.224:8971` |
| Media mount | `/mnt/frigate` |
| Hardware | Intel iGPU and USB Coral TPU |

Frigate serves HTTPS on port `8971` with a self-signed/default certificate, so validation uses `curl -k`.

Current minimal Frigate config has MQTT enabled and no cameras:

```yaml
mqtt:
  enabled: true
  host: <runtime-detected MQTT CT IP>
  port: 1883

cameras: {}
```

### CT 210 - MQTT

MQTT runs in CT 210 as native Mosquitto.

| Item | Value |
|---|---|
| CT ID | `210` |
| Hostname | `mqtt-core` |
| IP | `192.168.0.217` |
| Port | `1883` |

Current bootstrap Mosquitto config:

```text
listener 1883 0.0.0.0
allow_anonymous true
log_dest syslog
log_dest stdout
```

This is acceptable for initial LAN-only bootstrap, but should be hardened later with username/password auth and anonymous access disabled.

### VM 100 - Home Assistant

Home Assistant OS runs as VM 100.

| Item | Value |
|---|---|
| VM ID | `100` |
| Name | `homeassistant` |
| IP | `192.168.0.218` |
| URL | `http://192.168.0.218:8123` |
| HAOS image | `haos_ova-18.0.qcow2.xz` |

The onboarding page has been observed in a browser.

### CT 220 - Hermes

Hermes runs in CT 220.

| Item | Value |
|---|---|
| CT ID | `220` |
| Hostname | `hermes-agent` |
| IP | `192.168.0.225` |
| User | `hermes` |
| Hermes home | `/home/hermes/.hermes` |
| Base dir | `/opt/hermes` |
| Hermes CLI | `/usr/local/bin/hermes` |
| Gateway service | `hermes-gateway.service` |
| Web UI | `http://192.168.0.225:9119` |
| Slack bot | `nad9hermes` |

CT 220 resource baseline:

```text
cores:     2
cpuunits:  2048
memory:    4096 MiB
swap:      0 MiB
features:  nesting=1,keyctl=1
cpulimit:  not explicitly configured
```

Current Hermes operating model:

- Provider: OpenRouter.
- Default model: `nvidia/nemotron-3-ultra-550b-a55b:free`.
- Gateway runs as a system-wide systemd service.
- Slack mention integration works with `@nad9hermes`.
- Web UI works but remains optional.
- Do not expose the Web UI directly to the internet.
- Do not chase optional Hermes doctor warnings unless they block real use.

## Daily Admin Commands

List guests:

```bash
pct list
qm list
```

Enter Hermes:

```bash
pct enter 220
su - hermes
```

Check Hermes:

```bash
hermes doctor
hermes gateway status
```

Restart Hermes gateway:

```bash
sudo hermes gateway restart --system
```

Check service status from the Proxmox host:

```bash
pct exec 220 -- systemctl status hermes-gateway.service --no-pager
pct exec 210 -- systemctl status mosquitto --no-pager
pct exec 200 -- bash -c 'cd /opt/frigate && docker compose ps'
qm status 100
```

## Next Real Project Step - Step 10

The next major work should be Home Assistant + MQTT + Frigate integration.

Step 10 validation scripts should discover runtime IP addresses from Proxmox guest/container state. Do not hardcode LAN IPs into Step 10 scripts because the network may change later. Frigate still requires a broker address in its own runtime config; rerun `scripts/step10d-frigate-mqtt-config.sh` if DHCP changes the MQTT CT address.

Suggested scope:

1. Verify Home Assistant is reachable with `scripts/step10a-homeassistant-reachability.sh`. Completed.
2. Verify the MQTT broker is reachable from the Home Assistant network path with `scripts/step10b-homeassistant-mqtt-network-validation.sh`. Completed.
3. Configure the MQTT integration in Home Assistant with the Home Assistant UI, then verify the stored MQTT config entry with `scripts/step10c-homeassistant-mqtt-integration.sh`. Pending.
4. Enable MQTT in the Frigate config with `scripts/step10d-frigate-mqtt-config.sh`. Completed.
5. Restart Frigate with `scripts/step10e-frigate-restart.sh`. Completed.
6. Verify Frigate publishes to MQTT with `scripts/step10f-frigate-mqtt-validation.sh`. Completed.
7. Add the Frigate integration in Home Assistant.
8. Add the first camera to Frigate.
9. Confirm camera/entities appear in Home Assistant.

Important rule: do not add new platform components until one camera is visible in Home Assistant through Frigate.

## Later Tasks

- Harden MQTT with username/password auth.
- Add first Frigate camera.
- Clean up Slack slash command conflicts if they become annoying.
- Update Hermes sudoers rules if operational needs change.
- Improve Hermes gateway validation log checks if needed.
- Configure OpenAI OAuth / Codex later if needed.
- Configure web search / xAI later if needed.
- Add remote access through VPN or a secure tunnel before the server moves behind mobile broadband.
