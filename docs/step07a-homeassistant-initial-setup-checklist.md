# Step 07A - Home Assistant Initial Setup Checklist

This step is manual and should be completed in the Home Assistant web UI.

Home Assistant URL:

```text
http://192.168.8.105:8123
```

## 1. Create owner account

Open Home Assistant in a browser and complete the welcome wizard.

Suggested account approach:

- Create one main owner/admin user.
- Use a strong password.
- Save the password in a password manager.
- Do not expose Home Assistant directly to the internet.

## 2. Set home location

During onboarding, configure:

- Country: Sweden
- Time zone: Europe/Stockholm
- Unit system: Metric
- Currency: SEK, if asked
- Home location: your home location, or approximate location if you prefer privacy

## 3. Confirm network access

From your workstation, confirm that this works:

```text
http://192.168.8.105:8123
```

From the Proxmox host, this has already been verified:

```bash
curl http://192.168.8.105:8123
```

Expected result:

```text
HTTP 200 or HTTP 302
```

## 4. Do not install random add-ons yet

For this build, core services are intentionally outside Home Assistant:

```text
Frigate:   CT 200, Docker
MQTT:      CT 210, Mosquitto
HAOS:      VM 100
```

Recommended approach:

- Do not install the Mosquitto add-on in Home Assistant.
- Do not install the Frigate add-on in Home Assistant.
- Use integrations to connect to the existing external services instead.

## 5. Add MQTT integration

In Home Assistant:

```text
Settings
Devices & services
Add integration
MQTT
```

Use:

```text
Broker: 192.168.8.103
Port:   1883
Username: empty
Password: empty
```

Current Mosquitto setup allows anonymous local LAN access.

Expected result:

```text
MQTT integration added successfully
```

Later hardening task:

```text
Add MQTT username/password
Restrict anonymous access
Update Frigate and Home Assistant MQTT config
```

## 6. Add Frigate integration later

Do not add Frigate immediately until Frigate has at least one camera configured.

Current Frigate URL:

```text
https://192.168.8.104:8971
```

Frigate is already running with:

```text
Intel iGPU passthrough
USB Coral TPU passthrough
Dedicated media disk /mnt/frigate
```

Later steps:

```text
Add first test camera to Frigate
Validate stream
Validate recording
Validate object detection
Then connect Frigate to Home Assistant
```

## 7. Check discovered devices

Home Assistant may auto-discover devices on the LAN.

Review discoveries carefully.

Recommended:

- Add only devices you recognize.
- Ignore unknown devices for now.
- Avoid making many changes before the core architecture is stable.

## 8. Create a backup after onboarding

After the initial Home Assistant setup is complete:

```text
Settings
System
Backups
Create backup
```

Suggested backup name:

```text
initial-haos-onboarding-vm100
```

Download a copy to your workstation.

## 9. Record important addresses

| Service | Location | URL / Address |
|---|---:|---|
| Proxmox | host | `https://192.168.8.10:8006` |
| Home Assistant | VM 100 | `http://192.168.8.105:8123` |
| Frigate | CT 200 | `https://192.168.8.104:8971` |
| MQTT | CT 210 | `192.168.8.103:1883` |

## 10. Current completion criteria

This step is complete when:

- Home Assistant owner account exists.
- Home Assistant web UI is reachable.
- Correct location, time zone, and metric units are set.
- MQTT integration is added using broker `192.168.8.103:1883`.
- Initial Home Assistant backup is created.
- No unnecessary add-ons were installed.

## Status

```text
Step 07A - Home Assistant initial setup checklist: manual
```
