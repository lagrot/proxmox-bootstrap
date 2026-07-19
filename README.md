# Proxmox Bootstrap

Modular Proxmox VE homelab bootstrap framework for `nad9-1`.

This repository contains Bash scripts, validation scripts, shared helper libraries, and documentation for building and maintaining the local Proxmox homelab environment.

## Current architecture

LAN service addresses are assigned by DHCP and pinned with router DHCP reservations.

```text
Proxmox Host: nad9-1
IP:           192.168.8.10
Tailscale:    100.66.43.1

VM 100: Home Assistant OS
  URL: http://192.168.8.105:8123

CT 200: docker-core
  Purpose: Docker Compose / Frigate
  Cameras: Tapo C200 and Tapo C320WS
  Frigate URL: https://192.168.8.104:8971
  Home Assistant integration URL: http://192.168.8.104:5000

CT 210: mqtt-core
  Purpose: Mosquitto MQTT broker
  MQTT: 192.168.8.103:1883

CT 220: hermes-agent
  Purpose: Hermes Agent / gateway / optional Web UI
  IP: 192.168.8.102
  Web UI: http://192.168.8.102:9119
```

## DHCP reservations

| Guest | MAC | Reserved IP |
|---|---|---:|
| VM 100 Home Assistant | `bc:24:11:cf:06:ba` | `192.168.8.105` |
| CT 200 docker-core / Frigate | `BC:24:11:B5:32:70` | `192.168.8.104` |
| CT 210 mqtt-core | `BC:24:11:C1:CB:79` | `192.168.8.103` |
| CT 220 hermes-agent | `BC:24:11:CB:82:7D` | `192.168.8.102` |

## Project principles

- One step at a time.
- Scripts must be readable and idempotent where practical.
- Validation scripts should verify deployment scripts.
- Keep secrets and API keys out of Git.
- Prefer Proxmox-native administration with `pct`, `qm`, and the Web UI.
- Use `pct enter` and `pct exec` instead of installing SSH into every LXC.
- Keep the setup simple and avoid unnecessary services.

## Repository layout

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

## Main scripts

- `scripts/step01-host-validation.sh`
- `scripts/step02-storage.sh`
- `scripts/step03-docker-lxc.sh`
- `scripts/step03b-docker-bootstrap.sh`
- `scripts/step03c-hardware-passthrough.sh`
- `scripts/step04-frigate-deploy.sh`
- `scripts/step04b-frigate-validation.sh`
- `scripts/step05-mqtt-lxc.sh`
- `scripts/step05b-mqtt-validation.sh`
- `scripts/step05c-mqtt-hardening.sh`
- `scripts/step05d-mqtt-auth-validation.sh`
- `scripts/step06-homeassistant-vm.sh`
- `scripts/step06b-homeassistant-validation.sh`
- `scripts/step08-hermes-lxc.sh`
- `scripts/step08b-hermes-validation.sh`
- `scripts/step08c-hermes-bootstrap.sh`
- `scripts/step08d-hermes-validation.sh`
- `scripts/step08f-hermes-gateway-validation.sh`
- `scripts/step09b-hermes-dashboard-service.sh`
- `scripts/step09c-hermes-dashboard-validation.sh`
- `scripts/step10a-homeassistant-reachability.sh`
- `scripts/step10b-homeassistant-mqtt-network-validation.sh`
- `scripts/step10c-homeassistant-mqtt-integration.sh`
- `scripts/step10d-frigate-mqtt-config.sh`
- `scripts/step10e-frigate-restart.sh`
- `scripts/step10f-frigate-mqtt-validation.sh`
- `scripts/step10g-frigate-tapo-camera-config.sh`
- `scripts/step10h-frigate-camera-validation.sh`
- `scripts/step10i-frigate-tpu-validation.sh`
- `scripts/step10j-frigate-gpu-validation.sh`
- `scripts/step10k-homeassistant-hacs-bootstrap.sh`
- `scripts/step10l-homeassistant-frigate-reload.sh`
- `scripts/step10m-homeassistant-frigate-dashboard.sh`
- `scripts/step10n-frigate-homeassistant-smoketest.sh`
- `scripts/step10o-frigate-event-recording-config.sh`
- `scripts/step10p-frigate-event-recording-validation.sh`
- `scripts/step12-backup.sh`
- `scripts/step12-backup-validation.sh`
- `scripts/step12b-backup-operation.sh`
- `scripts/step12c-backup-schedule.sh`
- `scripts/step12d-backup-operations-validation.sh`
- `scripts/step12e-homeassistant-restore-drill.sh`

## Remote access

Remote access is documented in `docs/step11-remote-access-tailscale.md`.

The complete Frigate/Home Assistant integration procedure is documented in
`docs/step10-frigate-homeassistant-integration.md`.

Current verified remote access:

- Proxmox over Tailscale SSH: `ssh root@100.66.43.1`
- Proxmox Web UI over Tailscale: `https://100.66.43.1:8006`
- VS Code Remote SSH target: `nad9-1`

## Legacy scripts

The `old/` directory contains scripts that are kept for historical reference but are not part of the current bootstrap path:

- `old/setup-frigate-disk.sh`
- `old/step1-host-validation.sh`

## Current verified milestones

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
| Step 05C | MQTT authentication hardening | verified |
| Step 05D | MQTT authentication validation | verified |
| Step 06 | Home Assistant OS VM | verified |
| Step 06B | Home Assistant validation | verified |
| Step 08 | Hermes Agent LXC base | verified |
| Step 08B | Hermes LXC validation | verified |
| Step 08C | Hermes bootstrap | verified |
| Step 08D | Hermes bootstrap validation | verified |
| Step 08F | Hermes gateway validation | verified |
| Step 10A | Home Assistant reachability | verified |
| Step 10B | Home Assistant to MQTT network path | verified |
| Step 10C | Home Assistant MQTT integration | verified |
| Step 10D | Frigate MQTT config | verified |
| Step 10E | Frigate restart | verified |
| Step 10F | Frigate MQTT publishing | verified |
| Step 10G | Frigate Tapo C200 camera configuration | verified |
| Step 10H | Frigate camera validation | verified |
| Step 10I | Frigate USB Coral TPU validation | verified |
| Step 10J | Frigate Intel GPU/VAAPI validation | verified |
| Step 10K | Home Assistant HACS bootstrap | verified |
| Step 10L | Home Assistant Frigate integration and Tapo C200 entities | verified |
| Step 10M | Home Assistant Frigate dashboard automation | verified |
| Step 10N | Frigate/Home Assistant smoke test | verified |
| Step 10O | Frigate event-only recording configuration | verified |
| Step 10P | Frigate event-only recording validation | verified |
| Step 11 | Remote access with Tailscale | verified |
| Step 12 | Local service backup and temporary restore validation | verified |
| Step 12B | Scheduled validated backup operation | verified |
| Step 12C | Weekly systemd timer and log rotation | verified |
| Step 12D | Backup operations validation | verified |
| Step 12E | Stopped Home Assistant VM restore drill | verified |

## Hermes CT 220 baseline

```text
cores:     2
cpuunits:  2048
memory:    4096 MiB
swap:      0 MiB
features:  nesting=1,keyctl=1
cpulimit:  not explicitly configured
```

## Common commands

Validate Bash syntax:

```bash
bash -n scripts/<script-name>.sh
```

Run a validation script:

```bash
bash scripts/step08b-hermes-validation.sh
```

List containers and VMs:

```bash
pct list
qm list
```

Enter Hermes CT:

```bash
pct enter 220
```

Run a command inside Hermes CT:

```bash
pct exec 220 -- systemctl status hermes-gateway.service --no-pager
```

## Notes

Do not commit secrets, API keys, .env files, logs, temporary backups, downloaded images, or generated runtime data.
