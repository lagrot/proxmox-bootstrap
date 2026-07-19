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
| Proxmox IP | `192.168.8.10` |
| Proxmox Tailscale IP | `100.66.43.1` |
| Proxmox VE | `9.2.3` |
| Kernel observed | `7.0.14-3-pve` |
| Hardware | Minisforum NAD9 |
| CPU | 12th Gen Intel Core i9-12900H |
| GPU | Intel iGPU |
| RAM | Initially 16 GiB |
| System storage | 512 GB NVMe for Proxmox / VM / LXC storage |
| Media storage | 512 GB SATA SSD dedicated to Frigate media |
| Accelerator | USB Coral TPU |
| Zigbee coordinator | Sonoff ZBDongle-P passed to HAOS VM 100; ZHA loaded |

Current Stockholm/fiber speed test observed:

| Direction | Result |
|---|---:|
| Download | 865.64 Mbit/s |
| Upload | 545.52 Mbit/s |
| Ping | 9.7 ms |

Network move note: this server has moved to the `192.168.8.0/24` network. Remote access is through Tailscale; do not expose Proxmox, Home Assistant, Frigate, MQTT, Hermes, or the Hermes Web UI directly to the internet. See `docs/step11-remote-access-tailscale.md`.

## Current Network And Remote Access

| Item | Value |
|---|---|
| LAN subnet | `192.168.8.0/24` |
| Proxmox LAN IP | `192.168.8.10/24` |
| LAN gateway | `192.168.8.1` |
| Proxmox Tailscale IP | `100.66.43.1` |
| Proxmox Tailscale name | `nad9-1` |
| DNS on Proxmox host | Tailscale, `100.100.100.100` |

LAN service addresses for VM 100 and CTs 200/210/220 are DHCP leases pinned with router DHCP reservations. The guests remain configured for DHCP; the router preserves the current addresses by MAC address.

| Guest | MAC | Reserved IP |
|---|---|---:|
| VM 100 Home Assistant | `bc:24:11:cf:06:ba` | `192.168.8.105` |
| CT 200 docker-core / Frigate | `BC:24:11:B5:32:70` | `192.168.8.104` |
| CT 210 mqtt-core | `BC:24:11:C1:CB:79` | `192.168.8.103` |
| CT 220 hermes-agent | `BC:24:11:CB:82:7D` | `192.168.8.102` |

Verified remote access:

- SSH to Proxmox over Tailscale from `rpi-1`: `ssh root@100.66.43.1`
- Proxmox Web UI over Tailscale: `https://100.66.43.1:8006`
- Proxmox Web UI on LAN: `https://192.168.8.10:8006`
- VS Code Remote SSH target: `nad9-1`

Tailscale device roles:

| Device | Tailscale IP | Tag | Intended access |
|---|---|---|---|
| `rpi-1` | `100.123.116.90` | `tag:trusted` | Full access / SSH jump host |
| `hermes-iot` | `100.89.33.12` | `tag:iot` | Only `tag:iot` destinations |
| `nad9-1` | `100.66.43.1` | `tag:server` | Server target, no access to `hermes-iot` |

Remote access rules:

- `group:admin` has full Tailscale access.
- `tag:trusted` has full Tailscale access.
- `tag:iot` can reach only `tag:iot` destinations.
- `rpi-1` is only the SSH jump host; use `nad9-1` as the VS Code remote target.
- `/root/.bashrc` on `nad9-1` must stay quiet for non-interactive SSH/SCP sessions.

## Current Architecture

```text
Proxmox Host nad9-1
IP: 192.168.8.10
Tailscale IP: 100.66.43.1

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
| Proxmox | host | `https://192.168.8.10:8006` |
| Proxmox via Tailscale | host | `https://100.66.43.1:8006` |
| Home Assistant | VM 100 | `http://192.168.8.105:8123` |
| Frigate | CT 200 | `https://192.168.8.104:8971` |
| MQTT / Mosquitto | CT 210 | `192.168.8.103:1883` |
| Hermes Agent | CT 220 | `192.168.8.102` |
| Hermes Web UI | CT 220 | `http://192.168.8.102:9119` |
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
| Step 05C | MQTT authentication hardening | verified |
| Step 05D | MQTT authentication validation | verified |
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
| Step 10C | Home Assistant MQTT integration | verified |
| Step 10D | Frigate MQTT config | verified |
| Step 10E | Frigate restart | verified |
| Step 10F | Frigate MQTT publishing | verified |
| Step 10G | Frigate Tapo camera config automation | verified |
| Step 10H | Frigate camera validation automation | verified |
| Step 10I | Frigate USB Coral TPU validation | verified |
| Step 10J | Frigate Intel GPU/VAAPI validation | verified |
| Step 10K | Home Assistant HACS bootstrap | verified |
| Step 10L | Home Assistant Frigate integration and two-camera entities | verified |
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
| Step 13 | Frigate snapshot and export retention policy | verified |
| Step 13B | Frigate media retention and capacity validation | verified |
| Step 14A | Face-recognition readiness assessment | verified research |
| Step 18A | Frigate stable-upgrade preflight | verified on 0.17.2 |
| Step 18B | Controlled Frigate upgrade executor | dry-run verified |
| Step 18C | Post-upgrade regression orchestration | baseline verified |
| Step 18D | Explicit Frigate rollback | restore-test verified |
| Step 19A | Sonoff ZBDongle-P passthrough to HAOS | verified |
| Step 19B | HAOS Zigbee hardware and ZHA integration | verified; pairing deferred |

## Service Decisions

- Home Assistant stays as HAOS VM 100.
- Mosquitto is external in CT 210, not a Home Assistant add-on.
- Frigate is external in CT 200 with Docker Compose, not a Home Assistant add-on.
- Hermes is isolated in CT 220.
- CT 200 is Frigate / Docker only.
- CT 210 is MQTT only.
- CT 220 is Hermes only.
- Frigate MQTT is enabled for the Home Assistant / MQTT / Frigate integration step.
- Do not add duplicate Mosquitto or Frigate add-ons inside Home Assistant.

## Current Services

### CT 200 - Frigate

Frigate runs in CT 200 through Docker Compose.

| Item | Value |
|---|---|
| CT ID | `200` |
| Hostname | `docker-core` |
| IP | `192.168.8.104` |
| Image | `ghcr.io/blakeblackshear/frigate:0.17.2` (pinned; upgrade deliberately after validation) |
| Authenticated URL | `https://192.168.8.104:8971` |
| Home Assistant integration URL | `http://192.168.8.104:5000` |
| Media mount | `/mnt/frigate` |
| Hardware | Intel iGPU and USB Coral TPU |

Frigate serves authenticated HTTPS on port `8971` with a self-signed/default certificate, so validation uses `curl -k`. Port `5000` is exposed for the Home Assistant integration as internal unauthenticated HTTP and must remain LAN-only; it must not be forwarded to the internet.

Current minimal Frigate config has MQTT enabled, Intel VAAPI decode, Intel GPU telemetry, and USB Coral detection:

```yaml
mqtt:
  enabled: true
  host: <runtime-detected MQTT CT IP>
  port: 1883

ffmpeg:
  hwaccel_args: preset-vaapi

telemetry:
  stats:
    intel_gpu_stats: true

detectors:
  coral:
    type: edgetpu
    device: usb

cameras:
  tplink_c200_1:
    # Full RTSP and stream settings are managed by Step 10G.
  tplink_c320ws_1:
    # Full RTSP and stream settings are managed by Step 10G.
```

### CT 210 - MQTT

MQTT runs in CT 210 as native Mosquitto.

| Item | Value |
|---|---|
| CT ID | `210` |
| Hostname | `mqtt-core` |
| IP | `192.168.8.103` |
| Port | `1883` |

Current bootstrap Mosquitto config:

```text
listener 1883 0.0.0.0
allow_anonymous true
log_dest syslog
log_dest stdout
```

This is the initial LAN-only bootstrap configuration. The hardened configuration is applied by `scripts/step05c-mqtt-hardening.sh` and uses a Mosquitto password file with `allow_anonymous false`.

MQTT hardening is automated by `scripts/step05c-mqtt-hardening.sh`. It creates the Mosquitto password database, disables anonymous access, updates Frigate credentials, validates the Mosquitto configuration, and restarts both services. Home Assistant credentials are a separate configuration-entry operation and are not edited by this script. Run `scripts/step05d-mqtt-auth-validation.sh` and `scripts/step10f-frigate-mqtt-validation.sh` afterward.

### VM 100 - Home Assistant

Home Assistant OS runs as VM 100.

| Item | Value |
|---|---|
| VM ID | `100` |
| Name | `homeassistant` |
| IP | `192.168.8.105` |
| URL | `http://192.168.8.105:8123` |
| HAOS image | `haos_ova-18.0.qcow2.xz` |

The onboarding page has been observed in a browser.

### CT 220 - Hermes

Hermes runs in CT 220.

| Item | Value |
|---|---|
| CT ID | `220` |
| Hostname | `hermes-agent` |
| IP | `192.168.8.102` |
| User | `hermes` |
| Hermes home | `/home/hermes/.hermes` |
| Base dir | `/opt/hermes` |
| Hermes CLI | `/usr/local/bin/hermes` |
| Gateway service | `hermes-gateway.service` |
| Web UI | `http://192.168.8.102:9119` |
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

## Step 10 Integration Status

The Home Assistant + MQTT + Frigate integration, two-camera smoke test, and
event-only recording policy are complete through Step 10P. The verified
workflow and operator notes are maintained in
`docs/step10-frigate-homeassistant-integration.md`.

Step 10 validation scripts should discover runtime IP addresses from Proxmox guest/container state. The current LAN addresses are pinned by router DHCP reservations, but scripts should still avoid hardcoding LAN IPs where practical. Frigate still requires a broker address in its own runtime config; rerun `scripts/step10d-frigate-mqtt-config.sh` if the MQTT CT address changes.

Suggested scope:

1. Verify Home Assistant is reachable with `scripts/step10a-homeassistant-reachability.sh`. Completed.
2. Verify the MQTT broker is reachable from the Home Assistant network path with `scripts/step10b-homeassistant-mqtt-network-validation.sh`. Completed.
3. Configure the MQTT integration in Home Assistant with the Home Assistant UI, then verify it through the Home Assistant API with `scripts/step10c-homeassistant-mqtt-integration.sh`. Completed.
4. Enable MQTT in the Frigate config with `scripts/step10d-frigate-mqtt-config.sh`. Completed.
5. Restart Frigate with `scripts/step10e-frigate-restart.sh`. Completed.
6. Verify Frigate publishes to MQTT with `scripts/step10f-frigate-mqtt-validation.sh`. Completed.
7. Install FFmpeg in CT 200 as the camera-test dependency during Frigate deployment. Completed.
8. Add the Frigate integration in Home Assistant. Completed.
9. Confirm both Tapo cameras and their entities appear in Home Assistant. Completed.
10. Validate live view, recording, detection, and MQTT events through Home Assistant. Completed successfully with `scripts/step10n-frigate-homeassistant-smoketest.sh`.

The HACS app repository and official Get HACS app are bootstrapped with `scripts/step10k-homeassistant-hacs-bootstrap.sh` through the Home Assistant OS guest-agent `ha` CLI. One-time GitHub device authorization remains an operator security step.

### Completed implementation tracks

The Frigate Home Assistant integration work will be split into independent tracks:

1. **Home Assistant integration track:** add the Frigate integration through the Home Assistant UI using `http://<Frigate-CT-IP>:5000`. Completed.
2. **API/entity verification track:** verify that the Frigate integration is loaded and that both Tapo devices and their camera entities are present through Home Assistant APIs and entity registries where available. Completed.
3. **Frigate baseline track:** run the existing camera, MQTT, Coral TPU, and Intel VAAPI validations in parallel to establish that the external Frigate service remains healthy during integration. Completed.
4. **Documentation track:** record only durable configuration decisions and verified entity names after the camera is visible in Home Assistant. Completed.

The Tapo C200 and C320WS cameras are visible through the Frigate integration.
Future platform additions should be evaluated separately from this completed
baseline.

## Remote Access

Remote access is documented in `docs/step11-remote-access-tailscale.md`.

Current verified access:

- SSH to Proxmox over Tailscale from `rpi-1`: `ssh root@100.66.43.1`
- Proxmox Web UI over Tailscale: `https://100.66.43.1:8006`
- Proxmox Web UI on LAN: `https://192.168.8.10:8006`
- VS Code Remote SSH target: `nad9-1`

## Backup And Restore Workstream

The current backup design is intentionally local and simple:

- Store service backups on Proxmox host storage.
- Do not encrypt the first implementation; protect the backup directory with
  restrictive filesystem ownership and permissions.
- Verify archive integrity, restore service archives into temporary directories,
  and perform a stopped temporary-VM restore drill for Home Assistant.
- Back up Home Assistant, Frigate configuration (not media by default),
  Mosquitto configuration and password database, and Hermes configuration/data.
- Run automatically each Sunday at 03:00 Europe/Stockholm with a persistent
  systemd timer and a randomized delay of up to ten minutes.
- Retain eight validated weekly backups. Retention runs only after the new
  backup passes checksum and temporary-extraction validation.
- Require estimated backup size plus 25 percent headroom while preserving at
  least 20 percent free space on the backup filesystem.
- Write status to systemd journal, a protected file log, and a root-only JSON
  status file. Rotate logs weekly, compress rotations, and retain 52 weeks.
- Treat an encrypted external/off-host copy as a follow-up improvement.

The scheduled service path, checksum validation, temporary extraction, status
reporting, timer, and logrotate configuration are verified. A Home Assistant
archive was restored to stopped temporary VM 900, its configuration and disks
were validated host-side, and the temporary VM and volumes were removed.
The procedure is documented in `docs/step12-backup-and-restore.md`.

## Completed Second Frigate Camera Integration

The Tapo C320WS was integrated as the second Frigate camera while preserving
the verified Tapo C200 baseline. The completed implementation covers:

1. Reserve or discover the C320WS LAN address and record its non-secret device
   identity and stream requirements.
2. Confirm the camera's supported RTSP streams and create the required local
   camera account without committing credentials.
3. Extend the Frigate camera configuration automation so it supports both the
   C200 and C320WS cleanly and idempotently.
4. Validate record and detect streams, Frigate health, Intel VAAPI decoding,
   Coral detection, MQTT events, recordings, and snapshots for the C320WS.
5. Verify that the second camera and its entities appear in Home Assistant.
6. Rerun the end-to-end Frigate/Home Assistant smoke test with both cameras.

Current implementation status:

- C320WS network access, RTSP port 554, and ONVIF port 2020 are verified.
- `/stream1` is verified as H.264 1280x720 at 15 FPS with mono G.711 A-law
  audio; `/stream2` is verified as H.264 640x360 at 15 FPS with the same audio.
- Frigate is healthy with both `tplink_c200_1` and `tplink_c320ws_1`; direct
  record/detect streams, API camera entries, Intel VAAPI, and Coral TPU passed.
- Home Assistant exposes 16 C320WS entities after an automated Frigate
  integration reload, and both camera entities report `recording`.
- Recent recording segments are verified for both cameras. MQTT availability
  is online.
- The two-camera smoke test completed with no failed tracks or warnings. A
  camera-specific C320WS `person` event was verified with both a snapshot and
  a video clip.

The second-camera integration is complete.

## Two-Camera Frigate Dashboard

The native dashboard automation now generates three responsive views for both
cameras:

1. **Live:** the default daily view, with prominent live video, compact camera
   availability, motion/person status, object counts, and a recording control.
2. **Review:** recent detections, recordings, snapshots, and navigation to
   Frigate Review or Home Assistant Media Browser. Start with supported native
   features, then evaluate Advanced Camera Card for richer timeline and media
   playback.
3. **System/Admin:** advanced detection, motion, snapshot, and review switches;
   recent activity history; verified diagnostics; and links to Frigate and
   entity details. Keep these controls away from the limited daily-use screen.

The updated configuration was accepted by Home Assistant and verified through
the WebSocket API as three views with 32 cards in total. The script remains
idempotent, validates all referenced entities before saving, and does not show
TPU or GPU status because reliable Home Assistant entities are not available.
The desktop layout is visually verified. Live streams, review images, controls,
diagnostics, and history render correctly; activity graph rows use compact
`Motion` and `Person` labels. Icon-only view navigation is retained because
Home Assistant displays each view title on hover.

## Event-Only Frigate Recording

Frigate 0.17.2 now retains video only for tracked-object alerts and detections.
Continuous and motion-only retention are both zero. Alert and detection video
is retained for ten days with five seconds of pre-capture and post-capture.
The current tracked-object list contains `person`, so idle video and motion
without a confirmed tracked object are not retained. Camera snapshots are
retained for ten days through the global snapshot policy.

The policy is applied by `scripts/step10o-frigate-event-recording-config.sh`
and verified for both cameras through the effective Frigate API config by
`scripts/step10p-frigate-event-recording-validation.sh`. Frigate container
health and startup logs also passed. No zones or masks are configured while
the cameras remain in temporary locations.

Both cameras use `preset-rtsp-generic` for their direct RTSP record and detect
inputs. The earlier restream preset omitted timestamp normalization intended
for direct cameras and caused visible C200 freeze-and-catch-up playback. In a
retained post-fix C200 segment, the worst measured frame gap improved from 411
ms to 97 ms, gaps of at least 250 ms dropped from ten to zero, and near-zero
burst gaps dropped from 90 to three while preserving approximately 25 FPS. A
fresh C320WS segment measured approximately 15 FPS with no 250 ms gaps.

## Frigate Snapshot And Export Retention

Step 13 completes the dedicated Frigate SSD retention policy. Both cameras
inherit one global ten-day snapshot retention value, matching the ten-day
alert/detection video policy. Per-camera snapshot retention overrides are
removed so future policy changes have one authoritative setting.

Exports are deliberate operator-created artifacts and are not automatically
deleted. The read-only Step 13B audit reports SSD capacity, snapshot/clip file
count and size, export count and size, and the oldest export. It warns when SSD
usage reaches 80 percent or when exports are older than 30 days. An age warning
requires manual review; it never authorizes deletion.

The deployment validates a candidate configuration with the pinned Frigate
image before installation, stores the previous config as
`/opt/frigate/config/config.yml.bak-media-retention`, restarts Frigate, and
waits for container health. The procedure is documented in
`docs/step13-frigate-media-retention.md`.

## Face-Recognition Readiness

Step 14A is a read-only assessment; face recognition remains disabled. Frigate
0.17.2 exposes its native local face-recognition configuration and currently
selects the CPU-oriented `small` model. CT 200 has four cores and 4096 MiB RAM,
and its Intel i9-12900H exposes the required AVX and AVX2 instructions. The
Intel render device is readable inside Frigate for a possible later
GPU/OpenVINO experiment. The Coral continues to handle object detection and
does not accelerate face-recognition enrichments.

Both cameras currently process 640x360 detect streams at 5 FPS with no skipped
frames. This is operationally healthy, but the limited resolution may only
provide reliable recognition for clear, close faces. The measured pre-pilot
baseline was approximately 24.2 ms Coral inference, 1.7 percent Frigate CPU,
and 50.9 percent Frigate-reported memory. These are point-in-time baselines,
not capacity guarantees.

The system is ready for a controlled one-camera `small`-model pilot with two
quality warnings, one for each detect-stream resolution. Pilot camera
selection must consider final placement, expected face size, and privacy; it
is not automatically assigned to the higher-resolution camera model because
both current detect streams have the same resolution. Only consenting
household members may be enrolled, visitors must not be auto-enrolled, and all
face processing and training data must remain local. The assessment and next
decision gates are documented in `docs/step14-face-recognition.md`.

## Controlled Frigate Upgrade Procedure

Steps 18A-18D provide a version-independent procedure for later stable Frigate
upgrades. They require an exact numeric image tag, explicit release-note review,
target-image config validation, a stopped-state backup, exact version/health
checks, the complete regression suite, and matching config/database rollback.
Moving tags and prerelease strings are rejected.

The tooling has been safely tested against the current pinned `0.17.2`
baseline: Step 18A passed without mutation, Step 18B passed in dry-run mode,
Step 18C passed all seven regression tracks in baseline mode, and Step 18D
passed a temporary restore test. No real Frigate upgrade or production rollback
has been performed. Frigate remains pinned to `0.17.2`.

The complete operator procedure and acceptance/rollback boundaries are in
`docs/step18-frigate-upgrade.md`.

## Home Assistant Zigbee Coordinator

Step 19 passes the Sonoff ZBDongle-P (`10c4:ea60`) through to HAOS VM 100 as
Proxmox `usb0`. A stopped-VM configuration backup was stored outside the
repository before the change. HAOS exposes the coordinator through its stable
`/dev/serial/by-id` identity, and Home Assistant's native ZHA integration
created a Zigbee network using the recommended setup path.

`scripts/step19a-homeassistant-zigbee-usb.sh` applies the passthrough
idempotently. `scripts/step19b-homeassistant-zigbee-validation.sh` verifies the
host device, VM configuration, HAOS serial identity, loaded ZHA config entry,
and continued Frigate USB access. Home Assistant and the Coral TPU regression
checks passed. No Zigbee end devices are available, so pairing and end-to-end
device control remain a deferred validation rather than a failure. The
operator procedure is documented in `docs/step19-homeassistant-zigbee.md`.

## Later Tasks

The agreed near-term roadmap is:

1. **Step 14 - Face recognition:** Step 14A readiness research is complete.
   Decide whether to proceed with a one-camera small-model pilot, select the
   camera based on final placement/privacy, and define accuracy acceptance
   criteria before deployment.
2. **Step 15 - Camera notifications:** design useful person/event alerts while
   preventing noisy or duplicate notifications.
3. **Step 16 - Hermes/Home Assistant research:** evaluate available APIs and
   integration patterns and decide whether CT 220 should remain the isolated
   Hermes gateway.
4. **Step 17 - Zones, masks, and detection tuning:** configure these after the
   cameras reach their final physical positions.
5. **Step 18 - Controlled Frigate upgrade procedure:** tooling and safe baseline
   tests are complete. Use it only after a later stable release is selected and
   reviewed. No production upgrade has yet been performed.
6. **Step 19 - Zigbee coordinator:** ZHA, HAOS USB passthrough, coordinator
   discovery, and integration loading are verified. Pairing and end-to-end
   control validation must wait for the first Zigbee device.

The Proxmox host currently detects the ZBDongle-P as USB ID `10c4:ea60`
(Silicon Labs CP210x UART Bridge) and exposes the stable host path
`/dev/serial/by-id/usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_008d95d7e99def11be87cba661ce3355-if00-port0`.
Installation preserved the existing Coral USB passthrough and included a
stopped-VM configuration backup, repeatable passthrough automation, HAOS
hardware discovery, and integration-state validation. A pairing test remains
deferred until a Zigbee device becomes available.

Additional later work:

- After visually validating the native dashboard, evaluate Advanced Camera
  Card only if richer Review timeline and media playback are needed.
- Clean up Slack slash command conflicts if they become annoying.
- Update Hermes sudoers rules if operational needs change.
- Improve Hermes gateway validation log checks if needed.
- Configure OpenAI OAuth / Codex later if needed.
- Configure web search / xAI later if needed.
