# Proxmox Command Cheat Sheet

This cheat sheet is for the current homelab project on `nad9-1`.

## Current project services

| Service | Type | ID | Name | Address |
|---|---:|---:|---|---|
| Proxmox host | host | - | nad9-1 | `192.168.8.10` |
| Home Assistant OS | VM | 100 | homeassistant | `http://192.168.8.105:8123` |
| Frigate | LXC | 200 | docker-core / frigate-core | `https://192.168.8.104:8971` |
| MQTT / Mosquitto | LXC | 210 | mqtt-core | `192.168.8.103:1883` |
| Hermes Agent | LXC | 220 | hermes-agent | `192.168.8.102` |

## Basic list commands

```bash
# List virtual machines
qm list

# List LXC containers
pct list
```

## Show configuration

```bash
# Home Assistant VM
qm config 100

# Frigate LXC
pct config 200

# MQTT LXC
pct config 210

# Hermes LXC
pct config 220
```

## Check status

```bash
# VM status
qm status 100

# LXC status
pct status 200
pct status 210
pct status 220
```

## Start, stop, reboot

### Virtual machines

```bash
# Start Home Assistant VM
qm start 100

# Graceful shutdown
qm shutdown 100

# Reboot
qm reboot 100

# Force stop, only if needed
qm stop 100
```

### LXC containers

```bash
# Start containers
pct start 200
pct start 210
pct start 220

# Graceful shutdown
pct shutdown 200
pct shutdown 210
pct shutdown 220

# Reboot containers
pct reboot 200
pct reboot 210
pct reboot 220

# Force stop, only if needed
pct stop 200
pct stop 210
pct stop 220
```

## Enter an LXC container

Use `pct enter` from the Proxmox host.

```bash
# Enter Frigate LXC
pct enter 200

# Enter MQTT LXC
pct enter 210

# Enter Hermes LXC
pct enter 220
```

Exit the container shell:

```bash
exit
```

## Run one command inside an LXC

Use `pct exec` for one-off commands.

```bash
# Show IP address
pct exec 200 -- hostname -I
pct exec 210 -- hostname -I
pct exec 220 -- hostname -I

# Show hostname
pct exec 220 -- hostname
```

## Switch to Hermes user

```bash
pct enter 220
su - hermes
hermes --help
```

Or as one command:

```bash
pct exec 220 -- su - hermes
```

## Home Assistant useful commands

```bash
# VM status
qm status 100

# VM configuration
qm config 100

# Check guest agent
qm agent 100 ping

# Show network interfaces from guest agent
qm agent 100 network-get-interfaces
```

Home Assistant URL:

```text
http://192.168.8.105:8123
```

Test from Proxmox host:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://192.168.8.105:8123
```

Expected good result:

```text
200 or 302
```

## Frigate useful commands

Frigate runs in CT 200 through Docker Compose.

```bash
# Docker containers
pct exec 200 -- docker ps

# Frigate compose status
pct exec 200 -- bash -c 'cd /opt/frigate && docker compose ps'

# Frigate logs
pct exec 200 -- docker logs --tail 100 frigate

# Follow Frigate logs
pct exec 200 -- docker logs -f frigate

# Restart Frigate
pct exec 200 -- bash -c 'cd /opt/frigate && docker compose restart frigate'
```

Frigate URL:

```text
https://192.168.8.104:8971
```

Run validation:

```bash
bash scripts/step04b-frigate-validation.sh
```

## MQTT / Mosquitto useful commands

MQTT runs in CT 210.

```bash
# Service status
pct exec 210 -- systemctl status mosquitto

# Is active?
pct exec 210 -- systemctl is-active mosquitto

# Is enabled?
pct exec 210 -- systemctl is-enabled mosquitto

# Check listener
pct exec 210 -- ss -ltnp | grep ':1883'

# Logs
pct exec 210 -- journalctl -u mosquitto --no-pager -n 80
```

MQTT broker:

```text
192.168.8.103:1883
```

Local MQTT pub/sub test:

```bash
pct exec 210 -- bash -c 'timeout 5 mosquitto_sub -h 127.0.0.1 -t homelab/validation -C 1 > /tmp/mqtt-validation.out & sleep 1; mosquitto_pub -h 127.0.0.1 -t homelab/validation -m mqtt-validation-ok; wait; cat /tmp/mqtt-validation.out'
```

Expected result:

```text
mqtt-validation-ok
```

Run validation:

```bash
bash scripts/step05b-mqtt-validation.sh
```

## Hermes useful commands

Hermes base LXC is CT 220.

```bash
# Enter container
pct enter 220

# Become hermes user
su - hermes

# Hermes help
hermes --help
```

One-off commands:

```bash
# Check Hermes CLI
pct exec 220 -- bash -c 'PATH=/usr/local/bin:/usr/bin:/bin hermes --help'

# Check service file
pct exec 220 -- systemctl cat hermes-gateway.service

# Service status
pct exec 220 -- systemctl status hermes-gateway

# Logs
pct exec 220 -- journalctl -u hermes-gateway --no-pager -n 80
```

Current state after Step 08C:

```text
Hermes CLI installed.
hermes-gateway.service exists.
Service is not enabled.
Service is not started.
API keys and provider configuration are not added yet.
```

Run validation:

```bash
bash scripts/step08b-hermes-validation.sh
```

## Proxmox storage commands

```bash
# Show storage status
pvesm status

# Show disks
lsblk

# Show mounts
findmnt

# Show Frigate disk mount
findmnt /mnt/frigate
```

## Network commands

```bash
# Host IP addresses
ip addr

# Routes
ip route

# DNS test
getent hosts deb.debian.org

# Speed test
speedtest-cli --simple

# Ping test
ping -c 20 1.1.1.1
```

## Project validation scripts

Run from the repo directory:

```bash
cd /root/proxmox-bootstrap
```

Validation scripts:

```bash
bash scripts/step01-host-validation.sh
bash scripts/step04b-frigate-validation.sh
bash scripts/step05b-mqtt-validation.sh
bash scripts/step06b-homeassistant-validation.sh
bash scripts/step08b-hermes-validation.sh
```

## Current verified project state

| Step | Description | Status |
|---|---|---|
| Step 01 | Host validation | verified |
| Step 02 | Storage | verified |
| Step 03 | Docker/LXC foundation | verified |
| Step 03b | Docker bootstrap in CT 200 | verified |
| Step 03c | Hardware passthrough | verified |
| Step 04 | Frigate deployment | verified |
| Step 04B | Frigate validation | verified |
| Step 05 | MQTT LXC deployment | verified |
| Step 05B | MQTT validation | verified |
| Step 06 | Home Assistant OS VM | verified |
| Step 06B | Home Assistant validation | verified |
| Step 07A | Home Assistant setup checklist | documentation |
| Step 07B | Frigate/MQTT/HA integration | documentation |
| Step 08 | Hermes Agent LXC base | verified |
| Step 08B | Hermes LXC validation | verified |
| Step 08C | Hermes bootstrap | verified |

## Recommended admin model

Use the Proxmox host as the main admin entry point:

- SSH to Proxmox host.
- Then use `pct enter` / `pct exec` for LXC containers.
- Use `qm` for VMs.

Recommended:

```bash
ssh root@192.168.8.10
pct enter 220
```

Avoid installing SSH inside every LXC unless there is a specific need.
