# Step 10: Frigate and Home Assistant Integration

This document records the complete Step 10 integration workflow for this
project. It covers the external Frigate installation in CT 200, the MQTT
broker in CT 210, Home Assistant OS VM 100, the Tapo C200 camera, the USB
Coral TPU, Intel VAAPI decoding, and the Home Assistant Frigate integration.

## Architecture

| Component | Location | Address / endpoint |
|---|---|---|
| Home Assistant OS | VM 100 | `192.168.8.105:8123` |
| Frigate | CT 200 / Docker Compose | `https://192.168.8.104:8971` |
| Frigate integration API | CT 200 | `http://192.168.8.104:5000` |
| Mosquitto MQTT | CT 210 | `192.168.8.103:1883` |
| Tapo C200 | LAN camera | `192.168.8.107` |

Frigate remains external to Home Assistant. Do not install the Frigate Home
Assistant add-on. Home Assistant uses the Frigate custom integration and the
Frigate MQTT topics.

## Security decisions

- Port `8971` remains the authenticated Frigate web/API endpoint.
- Port `5000` is the internal unauthenticated HTTP endpoint used by Home
  Assistant on the private LAN.
- Port `5000` must not be forwarded by the router or exposed to the internet.
- Do not use Let’s Encrypt for the private IP address.
- The default Frigate certificate on port `8971` is self-signed. Browser
  certificate warnings on that endpoint are expected.
- `config/local.conf` is ignored by Git and must have mode `600` because it may
  contain camera credentials, Frigate credentials, and the Home Assistant API
  token.
- Never put secrets in this document, `README.md`, `AGENTS.md`, logs, or
  committed configuration examples.

## 1. Validate Home Assistant and MQTT networking

Run these from the Proxmox host:

```bash
bash scripts/step10a-homeassistant-reachability.sh
bash scripts/step10b-homeassistant-mqtt-network-validation.sh
```

These scripts discover the VM and CT addresses through Proxmox and verify:

- VM 100 is running and reachable.
- Home Assistant responds on port `8123`.
- CT 210 is running.
- Mosquitto listens on port `1883`.
- The Home Assistant and MQTT guests are on the expected network bridge.

## 2. Configure and validate MQTT in Home Assistant

The MQTT integration must be configured before the Frigate integration. MQTT
authentication is managed by the project scripts:

```text
Broker: runtime-detected CT 210 address
Port: 1883
Username/password: values from config/local.conf

To harden the broker and update Frigate:

```bash
bash scripts/step05c-mqtt-hardening.sh
bash scripts/step05d-mqtt-auth-validation.sh
```

Step 05C intentionally does not edit Home Assistant's internal config-entry
storage. Home Assistant still requires a supported API/config-flow operation
or a one-time UI update before its MQTT connection can be verified. The
current runtime log showed `Not authorized`, confirming that Home Assistant
still has the pre-hardening credentials.
```

For API validation, create a Home Assistant long-lived access token and add it
locally to `config/local.conf`:

```bash
chmod 600 config/local.conf
```

Add the token as a shell assignment without committing it:

```bash
HA_TOKEN="<long-lived-token>"
```

Then run:

```bash
bash scripts/step10c-homeassistant-mqtt-integration.sh
```

Step 10C validates the token and checks `/api/config` for the loaded `mqtt`
integration. Home Assistant OS guest-agent storage is not used because that
storage is not reliably readable through `qm guest exec`.

## 3. Enable and validate Frigate MQTT

The Frigate configuration must point to the runtime MQTT broker address:

```bash
bash scripts/step10d-frigate-mqtt-config.sh
bash scripts/step10e-frigate-restart.sh
bash scripts/step10f-frigate-mqtt-validation.sh
```

The validation authenticates to MQTT, checks the retained Frigate availability
message, verifies the Frigate config contains MQTT credentials, and scans
recent Frigate logs for MQTT failures.

## 4. Configure Tapo cameras

Set camera-specific values in `config/local.conf`. Use a separate local camera
account and password for each camera, keep them local, and never commit them.
The verified cameras are:

```text
Tapo C200
  Camera name: tplink_c200_1
  Camera address: 192.168.8.107
  Record stream: /stream1
  Detect stream: /stream2 at 640x360

Tapo C320WS
  Camera name: tplink_c320ws_1
  Camera address: 192.168.8.110
  Record stream: /stream1, H.264 1280x720 at 15 FPS
  Detect stream: /stream2, H.264 640x360 at 15 FPS

Shared settings
  RTSP port: 554
  ONVIF port: 2020
  Frigate detect rate: 5 FPS
```

Select the camera profile when applying or validating its configuration. The
configuration script updates only that camera block and preserves other
cameras:

```bash
TAPO_CAMERA_PROFILE=c200 bash scripts/step10g-frigate-tapo-c200-config.sh
TAPO_CAMERA_PROFILE=c320ws bash scripts/step10g-frigate-tapo-c200-config.sh
bash scripts/step10e-frigate-restart.sh
TAPO_CAMERA_PROFILE=c200 bash scripts/step10h-frigate-camera-validation.sh
TAPO_CAMERA_PROFILE=c320ws bash scripts/step10h-frigate-camera-validation.sh
```

Step 10H validates the Frigate configuration, Docker Compose file, camera
entry, direct record and detect RTSP streams, Frigate health, API camera list,
and recent camera-specific logs.

After adding a camera, reload the existing Home Assistant Frigate integration
and wait for its camera entity without restarting Home Assistant:

```bash
TAPO_CAMERA_PROFILE=c320ws bash scripts/step10l-homeassistant-frigate-reload.sh
```

## 5. Configure the Home Assistant Frigate endpoint

Frigate exposes two relevant endpoints:

```text
Browser and authenticated API: https://192.168.8.104:8971
Home Assistant integration:   http://192.168.8.104:5000
```

Port `5000` was added to the Docker Compose deployment because Home Assistant
does not trust Frigate’s default self-signed TLS certificate. The deployment
script maps both ports and Step 04B validates both endpoints.

Verify the deployment with:

```bash
bash scripts/step04b-frigate-validation.sh
```

## 6. Validate the Coral TPU and Intel GPU

The USB Coral TPU is used for object detection:

```bash
bash scripts/step10i-frigate-tpu-validation.sh
```

The live Frigate detector statistics should show a `coral` detector and an
inference speed around the observed 24 ms range. A warning that recent logs do
not mention Coral initialization is acceptable when live Coral statistics are
present.

Intel VAAPI is used for video decoding, not object detection:

```bash
bash scripts/step10j-frigate-gpu-validation.sh
```

This validates `/dev/dri/renderD128`, Docker GPU mapping, FFmpeg VAAPI support,
live FFmpeg arguments, Frigate GPU telemetry, and the absence of recent VAAPI
errors.

In the Frigate Metrics page, Coral appears under **Detectors**. Intel GPU
activity may appear as GPU telemetry or remain near `0.0%` when the workload is
light; the live FFmpeg VAAPI arguments are the stronger decode-use check.

## 7. Install HACS with the project script

The repository and HACS bootstrap are automated through the Home Assistant OS
guest-agent `ha` CLI:

```bash
bash scripts/step10k-homeassistant-hacs-bootstrap.sh
```

The script:

1. Adds `https://github.com/hacs/addons` if it is not already configured.
2. Refreshes the Home Assistant app store.
3. Attempts to install the official Get HACS app.
4. Falls back to the official HACS release ZIP if the Supervisor CLI does not
   expose the app.
5. Restarts Home Assistant Core.

The one-time GitHub device authorization cannot be performed safely by the
script. After the script completes:

1. Go to **Settings → Devices & services → Add integration**.
2. Add **HACS**.
3. Complete the GitHub device authorization.

If HACS does not appear immediately, perform a hard browser refresh.

## 8. Install and configure the Frigate Home Assistant integration

After HACS is configured:

1. Open **HACS → Home Assistant Community Store**.
2. Select **Frigate — Frigate integration for Home Assistant**.
3. Select **Download** and install the latest release.
4. Restart Home Assistant.
5. Go to **Settings → Devices & services → Add integration**.
6. Select **Frigate**.
7. Use this URL:

   ```text
   http://192.168.8.104:5000
   ```

## 9. Create a repeatable Frigate dashboard

The project can create a separate native Home Assistant dashboard without
overwriting the existing dashboard:

```bash
bash scripts/step10m-homeassistant-frigate-dashboard.sh
```

The script creates the `frigate-dashboard` dashboard for both the Tapo C200
and Tapo C320WS. It uses only native Home Assistant cards and contains three
responsive views:

- **Live:** both live streams, current motion/person status and counts, plus
  the two recording switches.
- **Review:** the latest person image and review/count state for each camera,
  with navigation to Home Assistant Media Browser and Frigate Review.
- **System:** advanced detection, motion, snapshot and review switches; 24-hour
  activity history; camera state diagnostics; and a Frigate link.

Advanced controls are intentionally kept off the limited daily-use Live view.

The dashboard is created through the Home Assistant WebSocket API and is
idempotent. Before saving, the script verifies that every referenced entity
exists in Home Assistant. If the `frigate-dashboard` dashboard already exists,
it is preserved. To intentionally replace its generated configuration:

```bash
FORCE_UPDATE=1 bash scripts/step10m-homeassistant-frigate-dashboard.sh
```

Open it at:

```text
http://192.168.8.105:8123/frigate-dashboard
```

Advanced Camera Card is not required for this native baseline. Evaluate it
later only if richer timeline, clip, or recording playback inside the Review
view is worth the additional frontend dependency.

## 10. Final verification

Run the baseline checks again after the Home Assistant integration is added:

```bash
bash scripts/step10a-homeassistant-reachability.sh
bash scripts/step10b-homeassistant-mqtt-network-validation.sh
bash scripts/step10c-homeassistant-mqtt-integration.sh
bash scripts/step10f-frigate-mqtt-validation.sh
bash scripts/step10h-frigate-camera-validation.sh
bash scripts/step10i-frigate-tpu-validation.sh
bash scripts/step10j-frigate-gpu-validation.sh
```

The current verified entities include:

```text
camera.tplink_c200_1
binary_sensor.tplink_c200_1_motion
binary_sensor.tplink_c200_1_person_occupancy
switch.tplink_c200_1_detect
switch.tplink_c200_1_recordings
switch.tplink_c200_1_snapshots
```

Then verify in Home Assistant:

- Frigate integration is loaded. Completed.
- The Tapo C200 device exists. Completed.
- A camera entity exists. Completed.
- Live view works. Verified.
- Recording and detection switches/entities are available.
- MQTT events and object sensors update.

Do not add additional Home Assistant platform components until one camera is
visible through the Frigate integration.

## 11. Run the end-to-end smoke test

Run the smoke test from the Proxmox host:

```bash
bash scripts/step10n-frigate-homeassistant-smoketest.sh
```

The script runs four independent tracks in parallel:

- Frigate container health, port 5000, and Tapo C200 configuration.
- Home Assistant API access and required Frigate entities.
- Recent event recording segment output.
- MQTT availability and a bounded live `frigate/events` capture.

During the MQTT event window, move in front of either camera. Missing recent
event recordings or a missing event are reported as activity-dependent
warnings; a broken service, missing entity, or unavailable API is an error.

The smoke test is read-only and does not change Frigate, MQTT, or Home
Assistant configuration.

## 12. Retain only event video

Frigate 0.17.2 is configured to keep video only when a tracked-object alert or
detection occurs. The current tracked-object list contains `person`. This does
not require zones and applies to both cameras:

- continuous retention: zero days;
- motion-only retention: zero days;
- alert and detection video: ten days;
- event capture: five seconds before and after the event;
- camera snapshots: fourteen days, unchanged.

Apply, restart, and validate from the Proxmox host:

```bash
bash scripts/step10o-frigate-event-recording-config.sh
bash scripts/step10e-frigate-restart.sh
bash scripts/step10p-frigate-event-recording-validation.sh
```

The validation checks the effective Frigate API configuration for both
cameras, container health, and startup logs. Existing motion recordings are
not removed immediately; they expire according to the previous retention
policy. Zones and masks should be added only after final camera placement.

## Troubleshooting

### Frigate cannot be found in Home Assistant

Confirm the integration was downloaded in HACS and restart Home Assistant.
The Frigate entry is installed through HACS; it is not a Home Assistant OS app.

### `Config flow could not be loaded: Invalid handler specified`

Check the Core logs for a missing HACS module. Re-run:

```bash
bash scripts/step10k-homeassistant-hacs-bootstrap.sh
```

The bootstrap script uses the official release ZIP rather than a source archive
so all HACS runtime modules are present.

### Home Assistant cannot connect to Frigate

Use `http://192.168.8.104:5000`, not the self-signed HTTPS endpoint. Confirm
port 5000 from the Proxmox host:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://192.168.8.104:5000
```

### Frigate camera entities are absent

Run Step 10H and Step 10F. The Frigate camera must be healthy and Frigate must
be connected to the same MQTT broker as Home Assistant.

## Official references

- [Frigate Home Assistant integration](https://docs.frigate.video/integrations/home-assistant/)
- [Frigate authentication and ports](https://docs.frigate.video/configuration/authentication/)
- [Frigate recording retention](https://docs.frigate.video/configuration/record/)
- [HACS installation](https://hacs.xyz/docs/use/download/download/)
- [HACS initial configuration](https://hacs.xyz/docs/use/configuration/basic/)
