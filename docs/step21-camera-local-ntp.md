# Step 21C - Camera local NTP

Both cameras have router-side WAN blocking. They must obtain time locally
without reopening vendor-cloud access. Reuse the existing synchronized Chrony
service on `nad9-1`, rather than adding a guest or time daemon. Serve UDP 123
only on its discovered LAN address and IPv6 loopback, with access granted only
to the two configured camera IPv4 `/32` addresses. Do not enable router port
forwarding, advertise an unsynchronized local clock, or change upstream time
sources. Chrony's control socket remains configured as before.

## Host service

Run as root on `nad9-1`, with camera addresses in ignored `config/local.conf`:

```bash
bash scripts/step21c-camera-local-ntp.sh --dry-run
bash scripts/step21c-camera-local-ntp.sh --apply
bash scripts/step21c-camera-local-ntp.sh --validate
```

The preview prints the exact proposed drop-in without changing Chrony.
Apply refuses unexpected existing NTP-server directives, parses the combined
configuration before installation, and manages only
`/etc/chrony/conf.d/proxmox-bootstrap-camera-ntp.conf`. It restarts Chrony only
when adding the drop-in. Validation requires host synchronization, allowed
camera addresses, denied unrelated clients, and the discovered LAN listener.
A failed installation removes the drop-in and restarts the previous
configuration. Upstream sources and the system clock policy are unchanged.

## Per-camera configuration

Existing local ONVIF camera-account credentials are read from
`config/local.conf`; no new package or cloud login is required. The C200 uses
`TAPO_C200_*` settings with the existing `TAPO_CAMERA_*` fallback. The C320WS
uses `TAPO_C320WS_*` settings. Never paste credentials or raw authenticated
requests into documentation or logs.

```bash
bash scripts/step21d-camera-ntp.sh --inspect c200
bash scripts/step21d-camera-ntp.sh --dry-run c200
bash scripts/step21d-camera-ntp.sh --apply c200
bash scripts/step21d-camera-ntp.sh --validate c200
bash scripts/step21d-camera-ntp.sh --validate-sync c200
bash scripts/step21d-camera-ntp.sh --dry-run c320ws
bash scripts/step21d-camera-ntp.sh --apply c320ws
bash scripts/step21d-camera-ntp.sh --validate c320ws
bash scripts/step21d-camera-ntp.sh --validate-sync c320ws
```

Apply saves the original NTP configuration in root-only
`/var/lib/proxmox-bootstrap/camera-ntp/c200.json`, sets the discovered host
address as the manual NTP server, and requires readback plus UTC within five
seconds of the synchronized host. It does not set time manually, change clock
mode, or call the timezone/DST setter. Failure restores the original NTP
configuration and exits nonzero. Original rollback state is retained; a retry
may reuse it when it matches the original configuration, or for a reboot when
the current configuration already matches the desired server and saved camera
identity. It never overwrites the original backup with the desired settings.
An already configured and synchronized camera needs no writes.

If the camera has not contacted the local server, the explicit one-camera
reboot workflow is:

```bash
bash scripts/step21d-camera-ntp.sh --apply-reboot c200
bash scripts/step21d-camera-ntp.sh --apply-reboot c320ws
```

This sets the manual server and sends one ONVIF reboot request. It interrupts
that camera's live view/recording, waits for it to return, and requires a new
Chrony client request plus UTC within five seconds of the host. It tolerates
the C200 firmware's default/DHCP readback after boot, but refuses a conflicting
explicit server. A camera already passing clock and host-client checks exits
without another reboot, including the known default-readback case. Operate on
one camera at a time, preserving the other camera's working baseline.

`--validate` checks strict configuration readback plus clock. `--validate-sync`
checks the host policy, camera clock, and a positive Chrony client counter. It
warns when firmware reports default/DHCP settings. A past counter alone does
not prove recent resynchronization or the next boot's behavior; observe request
counts over time. Counters reset when Chrony restarts, so this check correctly
fails until a new camera request has been seen.

The C200 boot pilot and subsequent C320WS rollout prove actual time
synchronization for both cameras. A saved server setting alone is insufficient.
Inspect
Chrony's numeric client counters to confirm the camera actually queried it:

```bash
chronyc -n clients
```

Then run the integration smoke test:

```bash
bash scripts/step10n-frigate-homeassistant-smoketest.sh
```

Deployment acceptance requires actual camera NTP traffic, correct UTC, a
correct current local overlay, preserved camera connectivity, and healthy
Frigate/Home Assistant. Observe the next daylight-saving transition separately.
Do not claim reboot persistence until a
separate controlled reboot test passes. Phone/mobile-data testing remains the
external check that the cameras' cloud paths stay blocked.

## Rollback

Restore both cameras' settings before removing the time service. The example
below shows C200; use the `c320ws` profile and its separate backup for C320WS:

```bash
bash scripts/step21d-camera-ntp.sh --rollback c200
bash scripts/step21c-camera-local-ntp.sh --rollback
```

Camera rollback restores the saved ONVIF NTP configuration and checks readback;
the firmware quirk means that readback cannot prove the underlying time-source
behavior after reboot. It does not turn the clock back or undo unrelated
camera settings. Host rollback removes only the exact
managed drop-in and restarts Chrony. Repeated host apply and rollback are safe.
It refuses to remove an unexpectedly edited file. Keep camera rollback state
for operator review rather than deleting it automatically.

## Validation evidence and remaining observation

Host deployment, allowed/denied access checks, synchronization, rollback,
reapply, and no-restart idempotency passed. Before the pilot the C200 reported
an August UTC date while the host and C320WS reported the current October
date. Both cameras reported DHCP NTP with no configured manual server.

The inspected firmware was C200 `1.4.6 Build 260709 Rel.27675n` and C320WS
`1.6.5 Build 260806 Rel.22454n`. No firmware changes were made.

The C200 initially accepted the host's manual NTP address without correcting
its clock or sending observed requests. An ONVIF NTP-mode refresh also failed
to synchronize and changed its reported DST flag. That setter is excluded.

The owner-authorized reboot then proved one NTPv3 request from the C200 to
`192.168.8.10:123` and a server reply, with the host's client counter increasing
from zero to one. The C200 corrected its August clock to the current date and
reported UTC within two seconds of the host and correct local CET time. The
original DST flag returned after reboot, and the timezone string remained
unchanged. Both camera entities returned to recording and the integration
smoke test passed with zero failed tracks; idle-event warnings were expected.

After boot, ONVIF reported DHCP/default NTP despite the observed use of the
manual server. The original strict checker therefore failed acceptance and
restored the saved configuration. Reapplying the explicit manual server
without reboot passed strict readback, synchronization checks, and repeated
apply without writes. The read-only synchronization check also passed.
A subsequent NTP request increased the host counter to two, confirming at
least one further poll after startup; this is not a long-term retention test.

The revised explicit reboot checker now requires new client traffic and UTC
acceptance while allowing the observed default readback. Its revised full
transaction is covered by isolated tests; it was not exercised with a second
real reboot. Long-term polling and future boot behavior,
and behavior across the next daylight-saving transition remain observation
items for the C200. No second C200 reboot was performed.

After the C200 pilot, the C320WS was configured with the same manual server.
It contacted host Chrony and corrected its UTC offset within about a minute,
without rebooting. Its explicit reboot command correctly detected current
synchronization and client evidence and skipped the reboot. Both cameras
passed strict readback, clock, and host-client validation; repeated apply made
no writes. Separate protected original settings are saved for both profiles.
The final two-camera smoke test passed with zero failed tracks and only
activity-dependent idle-event warnings. C320WS reboot persistence and live
C320WS rollback have not been exercised. Fifteen isolated checks cover camera
transactions, including C320WS reboot orchestration with default readback.

The owner confirmed both live timestamp overlays show the correct date and
local time, approximately two seconds apart. The current local NTP deployment
is complete. Continue observing poll counts, future boot behavior, and seasonal
time changes.
Do not alter LAN-wide DNS or reopen camera WAN access as an implicit workaround.

Isolated transaction and parsing tests:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 scripts/step21-camera-ntp-tests.py
```

References: [Chrony configuration](https://chrony-project.org/doc/4.8/chrony.conf.html),
[ONVIF device-management WSDL](https://www.onvif.org/ver10/device/wsdl/devicemgmt.wsdl),
and [TP-Link camera time troubleshooting](https://community.tp-link.com/en/home/forum/topic/269202).
