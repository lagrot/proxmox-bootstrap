# Step 21 - Camera Network Isolation

This step moves the Tapo cameras toward local-only operation without changing
their verified Frigate streams. Frigate continues to pull RTSP directly over
the LAN; the router blocks camera-initiated internet traffic.

Do not expose Frigate or the cameras through router port forwarding, UPnP,
DMZ, or a public unauthenticated proxy. Remote camera viewing must use a
separately authenticated gateway to Home Assistant or Frigate.

## Current pilot

The Tele2-branded Huawei 5G CPE 5 router has an active IPv4 IP-filter pilot for
only the fixed Tapo C320WS:

| Setting | Value |
|---|---|
| Filter mode | Block list |
| Device / LAN address | C320WS / `192.168.8.110` |
| Protocol | TCP/UDP |
| LAN port | `1-65535` |
| WAN address | `*.*.*.*` |
| WAN port | `1-65535` |

The rule was enabled on 2026-08-07. A phone using mobile data could no longer
open the C320WS Tapo live stream, confirming loss of Tapo Cloud access. Local
record and detect RTSP streams remained available, Frigate stayed healthy,
Home Assistant reported both cameras as recording, and the end-to-end smoke
test had no failed tracks. C320WS processing remained at approximately 5 FPS
with zero skipped FPS and no fresh post-filter camera errors.

This remains an observation pilot, not a completed two-camera deployment. Do
not add the equivalent C200 rule until the C320WS has completed the observation
period and the acceptance checks below pass. The unchanged C200 preserves the
second known-good camera path during the pilot.

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

After the unattended observation period, require all of the following before
changing the C200:

- Continuous C320WS recordings remain present.
- Frigate and Home Assistant live views work.
- Person detection, snapshots, and clips work.
- Camera timestamps remain correct without Tapo Cloud connectivity.
- Step 10H passes with a log window covering the intended review period.
- Step 10N has no failed tracks; activity-dependent warnings are acceptable
  only when their stated event did not occur during the test window.
- The Tapo live view still fails over mobile data.

Blocking the camera's internet path also prevents normal Tapo remote sharing
and may prevent cloud firmware checks or other vendor-cloud features. Firmware
updates remain deliberate maintenance and are not part of this pilot.

## Rollback

In the Huawei router, open **Advanced > Security > IP filter** and disable or
delete only the `192.168.8.110` rule. Confirm Tapo Cloud access returns, then
rerun Step 10H and Step 10N. Do not modify the C200 or any unrelated router
rules during rollback.
