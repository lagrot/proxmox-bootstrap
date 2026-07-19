# Step 19 - Home Assistant Zigbee Coordinator

Step 19 assigns the Sonoff ZBDongle-P coordinator to Home Assistant OS VM 100
and uses Home Assistant's native ZHA integration. The dongle is based on the
Texas Instruments CC2652P radio and is supported by ZHA.

## Deployment

Confirm that the dongle is connected to the Proxmox host, then run:

```bash
bash scripts/step19a-homeassistant-zigbee-usb.sh
```

The script verifies the expected USB and serial identities, stops VM 100 when
needed, stores a root-only VM configuration backup under
`/var/backups/proxmox-bootstrap/vm-configs`, assigns the dongle to the first
free Proxmox USB slot, restarts HAOS, and waits for its guest agent.

In Home Assistant, add the Zigbee Home Automation integration, select the
Sonoff `/dev/serial/by-id` entry, and use the recommended new-network setup.
Do not configure Zigbee2MQTT to use the same coordinator.

## Validation

Run:

```bash
bash scripts/step19b-homeassistant-zigbee-validation.sh
bash scripts/step06b-homeassistant-validation.sh
bash scripts/step10i-frigate-tpu-validation.sh
```

Step 19B checks the host USB identity, Proxmox passthrough, HAOS stable serial
identity, loaded ZHA config entry, and continued Frigate USB access. The Coral
validation may warn that recent logs do not repeat its startup message; live
detector statistics are the authoritative operational check.

No Zigbee end devices were available during initial setup. Coordinator and ZHA
health are verified, while joining a device and controlling it from Home
Assistant remain pending until the first device is available.

## References

- [Home Assistant ZHA integration](https://www.home-assistant.io/integrations/zha/)
- [Proxmox VE USB passthrough](https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf)
