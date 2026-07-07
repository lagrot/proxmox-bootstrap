# Proxmox Bootstrap

Modular Proxmox VE homelab bootstrap framework for `nad9-1`.

This repository contains Bash scripts, validation scripts, shared helper libraries, and documentation for building and maintaining the local Proxmox homelab environment.

## Current architecture

```text
Proxmox Host: nad9-1
IP:           192.168.0.223

VM 100: Home Assistant OS
  URL: http://192.168.0.218:8123

CT 200: docker-core
  Purpose: Docker Compose / Frigate
  Frigate URL: https://192.168.0.224:8971

CT 210: mqtt-core
  Purpose: Mosquitto MQTT broker
  MQTT: 192.168.0.217:1883

CT 220: hermes-agent
  Purpose: Hermes Agent / gateway / optional Web UI
  IP: 192.168.0.225
  Web UI: http://192.168.0.225:9119
Project principles
One step at a time
Scripts must be readable and idempotent where practical
Validation scripts should verify deployment scripts
Keep secrets and API keys out of Git
Prefer Proxmox-native administration with pct, qm, and the Web UI
Use pct enter and pct exec instead of installing SSH into every LXC
Keep the setup simple and avoid unnecessary services
Repository layout
config/
  defaults.conf

docs/
  Project documentation and manual setup notes

lib/
  Shared Bash framework helpers

logs/
  Local runtime logs, not committed

scripts/
  Deployment and validation steps
Main scripts
scripts/step01-host-validation.sh
scripts/step02-storage.sh
scripts/step03-docker-lxc.sh
scripts/step03b-docker-bootstrap.sh
scripts/step03c-hardware-passthrough.sh
scripts/step04-frigate-deploy.sh
scripts/step04b-frigate-validation.sh
scripts/step05-mqtt-lxc.sh
scripts/step05b-mqtt-validation.sh
scripts/step06-homeassistant-vm.sh
scripts/step06b-homeassistant-validation.sh
scripts/step08-hermes-lxc.sh
scripts/step08b-hermes-validation.sh
scripts/step08c-hermes-bootstrap.sh
scripts/step08d-hermes-validation.sh
scripts/step08f-hermes-gateway-validation.sh
Current verified milestones
Step 01   Host validation                         verified
Step 02   Frigate storage                         verified
Step 03   Docker LXC foundation                   verified
Step 03B  Docker bootstrap in CT 200              verified
Step 03C  Hardware passthrough                    verified
Step 04   Frigate deployment                      verified
Step 04B  Frigate validation                      verified
Step 05   MQTT LXC deployment                     verified
Step 05B  MQTT validation                         verified
Step 06   Home Assistant OS VM                    verified
Step 06B  Home Assistant validation               verified
Step 08   Hermes Agent LXC base                   verified
Step 08B  Hermes LXC validation                   verified
Step 08C  Hermes bootstrap                        verified
Step 08D  Hermes bootstrap validation             verified
Step 08F  Hermes gateway validation               verified
Hermes CT 220 baseline
cores:     2
cpuunits:  2048
memory:    4096 MiB
swap:      0 MiB
features:  nesting=1,keyctl=1
cpulimit:  not explicitly configured
Common commands

Validate Bash syntax:

bash -n scripts/<script-name>.sh

Run a validation script:

bash scripts/step08b-hermes-validation.sh

List containers and VMs:

pct list
qm list

Enter Hermes CT:

pct enter 220

Run a command inside Hermes CT:

pct exec 220 -- systemctl status hermes-gateway.service --no-pager
Notes

Do not commit secrets, API keys, .env files, logs, temporary backups, downloaded images, or generated runtime data.

