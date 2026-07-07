# Step 07B - Frigate / MQTT / Home Assistant Integration Notes

This step documents how the running services should be connected together.

It is a manual integration step in the Home Assistant and Frigate web UIs. It should not modify the Proxmox host, VM, or containers directly.

## Current service addresses

| Service | Location | Address |
|---|---:|---|
| Proxmox | host | `https://192.168.0.223:8006` |
| Home Assistant | VM 100 | `http://192.168.0.218:8123` |
| Frigate | CT 200 | `https://192.168.0.224:8971` |
| MQTT / Mosquitto | CT 210 | `192.168.0.217:1883` |

## Current architecture

```text
Proxmox Host nad9-1
│
├── VM 100: Home Assistant OS
│     └── Home Assistant Core / Supervisor
│
├── CT 200: frigate-core
│     └── Docker Compose
│           └── Frigate
│                 ├── Intel iGPU
│                 ├── USB Coral TPU
│                 └── /mnt/frigate media storage
│
└── CT 210: mqtt-core
      └── Mosquitto MQTT broker
```

## Goal

Home Assistant should use external services instead of local add-ons:

| Service | Deployment |
|---|---|
| MQTT broker | External Mosquitto in CT 210 |
| Frigate | External Frigate in CT 200 |
| HAOS | Home Assistant OS VM 100 |

This keeps the system modular and easier to troubleshoot.

## 1. Do not install duplicate add-ons

Do not install these Home Assistant add-ons:

- Mosquitto broker add-on.
- Frigate add-on.

Reason:

- Mosquitto is already running in CT 210.
- Frigate is already running in CT 200.
- Home Assistant should connect to them using integrations.

## 2. Add MQTT integration in Home Assistant

In Home Assistant:

```text
Settings
Devices & services
Add integration
MQTT
```

Use:

```text
Broker:   192.168.0.217
Port:     1883
Username: empty
Password: empty
```

Current Mosquitto configuration allows anonymous local LAN access.

Expected result:

```text
MQTT integration added successfully
```

## 3. Verify MQTT from the Proxmox host

MQTT has already been validated with:

```bash
bash scripts/step05b-mqtt-validation.sh
```

Expected good result:

- Mosquitto service is active.
- Mosquitto service is enabled.
- Mosquitto is listening on TCP port 1883.
- Local MQTT publish/subscribe test succeeded.
- MQTT validation completed successfully.

Current broker address:

```text
192.168.0.217:1883
```

## 4. Prepare Frigate MQTT configuration

Frigate currently has MQTT disabled in the minimal bootstrap config.

Before connecting Frigate to Home Assistant, Frigate should publish events to the MQTT broker.

Edit the Frigate config in CT 200:

```bash
pct exec 200 -- vi /opt/frigate/config/config.yml
```

Change the MQTT section from:

```yaml
mqtt:
  enabled: false
```

to:

```yaml
mqtt:
  enabled: true
  host: 192.168.0.217
  port: 1883
```

Then restart Frigate:

```bash
pct exec 200 -- bash -c 'cd /opt/frigate && docker compose restart frigate'
```

Validate Frigate again:

```bash
bash scripts/step04b-frigate-validation.sh
```

## 5. Add the first camera before adding the Frigate integration

Do not add the Frigate Home Assistant integration until at least one camera exists in Frigate.

Reason:

```text
The integration is more useful after Frigate has cameras, events, and MQTT topics.
```

Recommended order:

```text
1. Add one test camera to Frigate.
2. Validate live view in Frigate.
3. Validate recording.
4. Validate object detection.
5. Confirm Frigate publishes MQTT events.
6. Add Frigate integration in Home Assistant.
```

## 6. Example Frigate camera skeleton

Use this only as a starting template. Replace the RTSP URL with the real camera stream.

```yaml
mqtt:
  enabled: true
  host: 192.168.0.217
  port: 1883

ffmpeg:
  hwaccel_args: preset-vaapi

detectors:
  coral:
    type: edgetpu
    device: usb

record:
  enabled: true
  retain:
    days: 7
    mode: motion

snapshots:
  enabled: true
  retain:
    default: 30

cameras:
  test_camera:
    enabled: true
    ffmpeg:
      inputs:
        - path: rtsp://USER:PASSWORD@CAMERA_IP:554/stream1
          roles:
            - detect
            - record
    detect:
      enabled: true
      width: 1280
      height: 720
      fps: 5
```

Notes:

- Use the correct RTSP path for the camera model.
- Start with one camera only.
- Validate stability before adding more cameras.
- Avoid high FPS for detection.
- Use iGPU for decoding and Coral for detection.

## 7. Validate MQTT topics from Frigate

After enabling MQTT in Frigate and restarting it, check whether topics appear.

From CT 210:

```bash
pct exec 210 -- timeout 20 mosquitto_sub -h 127.0.0.1 -t 'frigate/#' -v
```

If Frigate is publishing, you should see messages under:

```text
frigate/...
```

If there is no output:

- Check that Frigate MQTT is enabled.
- Check the broker IP.
- Check Frigate logs.
- Check that at least one camera is configured.

Frigate logs:

```bash
pct exec 200 -- docker logs --tail 100 frigate
```

## 8. Add Frigate integration in Home Assistant

After MQTT and one camera are working:

```text
Settings
Devices & services
Add integration
Frigate
```

Use the Frigate URL:

```text
https://192.168.0.224:8971
```

If Home Assistant rejects the self-signed certificate or HTTPS endpoint, test with the Frigate documentation and current integration behavior before changing the deployment. A later improvement could add a trusted certificate or reverse proxy.

## 9. Home Assistant entities to expect

After MQTT and Frigate are connected, Home Assistant may expose entities such as:

- Camera entities.
- Motion sensors.
- Object detection sensors.
- Occupancy sensors.
- Recording/event switches.
- Diagnostic entities.

Exact names depend on:

- Camera names in Frigate config.
- MQTT topic prefix.
- Frigate integration behavior.
- Enabled detectors and zones.

## 10. MQTT hardening later

Current MQTT is intentionally simple:

```text
allow_anonymous true
listener 1883 0.0.0.0
```

This is acceptable for initial LAN-only bootstrap, but should be hardened later.

Later hardening plan:

```text
1. Create a Mosquitto username/password.
2. Disable anonymous access.
3. Update Frigate MQTT config with credentials.
4. Update Home Assistant MQTT integration with credentials.
5. Re-run MQTT validation.
6. Re-run Frigate validation.
```

Possible future Mosquitto config:

```text
listener 1883 0.0.0.0
allow_anonymous false
password_file /etc/mosquitto/passwd
log_dest syslog
log_dest stdout
```

## 11. Mobile router / country-house note

This system is planned to run later behind a 4G/5G mobile router at the country house.

Important points:

- Do not expose Home Assistant, Frigate, MQTT, or Proxmox directly to the internet.
- Use VPN or a secure tunnel for remote access.
- Expect variable upload speed and latency on 4G/5G.
- Remote Frigate viewing depends more on upload stability than download speed.

Before moving the server, test:

```bash
speedtest-cli --simple
ping -c 20 1.1.1.1
```

Useful things to record at the country house:

- Download speed.
- Upload speed.
- Ping latency.
- Packet loss.
- Mobile router signal strength.
- Whether connection is 4G, 5G NSA, or 5G SA.

## 12. Completion criteria

Step 07B is complete when:

- Home Assistant MQTT integration is connected to `192.168.0.217:1883`.
- Frigate config has MQTT enabled.
- Frigate can publish to MQTT.
- At least one camera is configured in Frigate.
- Home Assistant can see Frigate/MQTT entities.
- No duplicate Mosquitto or Frigate add-ons were installed in Home Assistant.

## Status

```text
Step 07B - Frigate / MQTT / Home Assistant integration notes: documentation
```
