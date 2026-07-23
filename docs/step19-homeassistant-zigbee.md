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
identity, loaded ZHA config entry, live temperature, humidity, and battery
entities from the paired sensor, and continued Frigate USB access. It matches
the sensor's default entity IDs using `3rths24bz`. Set
`ZIGBEE_SENSOR_ENTITY_MATCH` in `config/local.conf` if those IDs are renamed.
The Coral validation may warn that recent logs do not repeat its startup
message; live detector statistics are the authoritative operational check.

The first end device is a THIRDREALITY `3RTHS24BZ` temperature and humidity
sensor. ZHA paired it successfully, applied its built-in device quirk, and
created temperature, humidity, battery, firmware-update, and calibration-offset
entities. Initial live readings and subsequent reports were verified.

During the initial interview, ZHA logged transient Zigpy database foreign-key
errors and binding-table warnings. The device nevertheless completed
initialization and continued reporting temperature and humidity. Treat those
messages as actionable only if the device becomes unavailable, entities are
missing, or fresh readings stop arriving.

The sensor reported firmware file version 37 and offered stable version 40.
Leave the firmware unchanged until the current baseline has remained stable;
an available update is not required for successful pairing.

## Indoor Climate dashboard

Step 19C creates a compact native Home Assistant dashboard for the paired
sensor:

```bash
bash scripts/step19c-homeassistant-climate-dashboard.sh
```

The dashboard appears in the sidebar as **Indoor Climate** and uses only native
Home Assistant cards. Temperature and humidity each have a prominent current
reading and a 24-hour line graph; sensor battery is shown in a smaller tile.
This keeps the initial dashboard compact and avoids requiring Mushroom,
card-mod, or another HACS frontend dependency.

The script discovers the three live entities by model text rather than
hardcoding their complete entity IDs. If the entities are renamed, set
`ZIGBEE_SENSOR_ENTITY_MATCH` in `config/local.conf` to text shared by the new
IDs. The script preserves an existing dashboard by default. To deliberately
replace it with the repository version, run:

```bash
FORCE_UPDATE=1 bash scripts/step19c-homeassistant-climate-dashboard.sh
```

This layout follows Home Assistant's native sensor-card guidance and borrows
the compact, glanceable hierarchy commonly used by Mushroom and community
indoor-climate dashboards. More sensors can be added after their names and
final rooms are known.

## References

- [Home Assistant ZHA integration](https://www.home-assistant.io/integrations/zha/)
- [Home Assistant dashboard cards](https://www.home-assistant.io/dashboards/cards/)
- [Mushroom dashboard cards](https://github.com/piitaya/lovelace-mushroom)
- [Proxmox VE USB passthrough](https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf)
