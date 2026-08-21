# Step 21 - Camera Network Isolation

This step moves the Tapo cameras toward local-only operation without changing
their verified Frigate streams. Frigate continues to pull RTSP directly over
the LAN; the router blocks camera-initiated internet traffic.

Do not expose Frigate or the cameras through router port forwarding, UPnP,
DMZ, or a public unauthenticated proxy. Remote camera viewing must use a
separately authenticated gateway to Home Assistant or Frigate.

## Current configuration

The Tele2-branded Huawei 5G CPE 5 router has active IPv4 IP-filter rules for
both fixed Tapo cameras:

| Setting | Value |
|---|---|
| Filter mode | Block list |
| Device / LAN address | C320WS / `192.168.8.110`; C200 / `192.168.8.107` |
| Protocol | TCP/UDP |
| LAN port | `1-65535` |
| WAN address | `*.*.*.*` |
| WAN port | `1-65535` |

The C320WS rule was enabled on 2026-08-07 and observed for more than one week.
The C200 rule was enabled on 2026-08-21 after its clean local baseline passed.
With phone Wi-Fi disabled and mobile data active, the Tapo app cannot open
either camera, confirming loss of Tapo Cloud access. Local record and detect
RTSP streams remain available, Frigate stays healthy, Home Assistant reports
both cameras as recording, and the end-to-end smoke test has no failed tracks.

The two-camera local-only deployment is now active. The C320WS observation
period completed before the C200 rule was added. The rules block vendor-cloud
access while preserving Frigate's local RTSP paths.

The Huawei rule covers IPv4 TCP and UDP. The cellular Tapo test is the
authoritative check that the camera's usable cloud path is blocked; do not
infer complete protocol isolation from the rule text alone. A future dedicated
camera VLAN would also restrict lateral access to other LAN devices, which this
same-subnet WAN filter does not do.

## Validation

Run the camera-specific validation:

```bash
TAPO_CAMERA_PROFILE=c320ws \
  bash scripts/step10h-frigate-camera-validation.sh
```

Step 10H checks only a recent log window by default so an old recovered error
does not fail the current network validation. Override the one-hour window when
needed:

```bash
FRIGATE_CAMERA_LOG_LOOKBACK=6h TAPO_CAMERA_PROFILE=c320ws \
  bash scripts/step10h-frigate-camera-validation.sh
```

Then run the full integration smoke test:

```bash
bash scripts/step10n-frigate-homeassistant-smoketest.sh
```

Finally, disable Wi-Fi on a phone and try the C320WS live view in the Tapo app
over mobile data. The cloud view must fail while Frigate and Home Assistant
continue working locally. This external cloud-path check cannot be proven by a
script running on the Proxmox LAN.

## Acceptance criteria

The following network-isolation acceptance checks passed before completion:

- Continuous C320WS recordings remain present.
- Frigate and Home Assistant live views work.
- Person detection, snapshots, and clips work.
- Camera timestamps remain correct without Tapo Cloud connectivity.
- Step 10H passes for the C200. The C320WS has recurring Intel VAAPI/FFmpeg
  detect-process errors that predate and are independent of this WAN rule;
  its local streams recover and current processing remains healthy.
- Step 10N has no failed tracks; activity-dependent warnings are acceptable
  only when their stated event did not occur during the test window.
- The Tapo live view fails for both cameras over mobile data.

Blocking the camera's internet path also prevents normal Tapo remote sharing
and may prevent cloud firmware checks or other vendor-cloud features. Firmware
updates remain deliberate maintenance and are not part of this pilot.

## Rollback

In the Huawei router, open **Advanced > Security > IP filter** and disable or
delete only the affected camera rule (`192.168.8.110` or `192.168.8.107`).
Confirm the intended Tapo Cloud access returns, then rerun Step 10H and Step
10N. Do not modify the other camera or unrelated router rules during rollback.
