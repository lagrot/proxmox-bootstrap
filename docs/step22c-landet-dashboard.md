> Historical HA prototype/reference. The selected standalone viewer is published
> at https://landet.ostmarken.se; see [current deployment](step22d-landet-deployment.md).

# Step 22C - Landet dashboard usability trial

Start with the viewing screen only. The intended viewer is an older person
with no Home Assistant knowledge. If the owner does not find the screen easy
enough, stop here instead of publishing another hostname or inviting users.

Preview through the existing protected owner route:

<https://ha.ostmarken.se/landet-view/live>

Use the existing owner login for this trial. Two large buttons, **Kameror** and **Temperatur**, switch between the only
two views. The camera view contains two native live pictures labelled
**Kamera 1** and **Kamera 2**. Tap, double-tap, and hold actions on the pictures
are disabled. The temperature view shows large current readings for
**Vardagsrum**, **Sovrum**, **Örnnästet**, and **Utomhus**, discovered from the
existing climate dashboards. Unavailable readings show **Ingen mätning**.
The three indoor cards also show **Luftfuktighet**. The outdoor thermometer
has no humidity measurement. Each card has small rolling 24-hour graphs; tap
the graphs to open a simple **Välj datum** dialog with a **Stäng** button.
Calendar days use the HA site timezone, including 23/25-hour seasonal days.
Available older dates depend on HA Recorder retention; missing history is
shown explicitly rather than inventing values. The two main navigation
buttons remain limited to the two internal view paths. The responsive layout permits side-by-side
pictures on wider screens and stacked pictures on smaller screens. There are
no Review/System tabs, recording switches, or Frigate LAN links. Under the
live cameras, **Senaste klipp** shows up to ten latest completed retained
events with thumbnails, camera names, and local dates/times. Tapping a clip
opens a player with **Stäng** and normal playback controls. The list refreshes
while visible, and **Uppdatera** permits a manual retry. Empty/unavailable
media is handled explicitly; retention and recording rules are unchanged.
Both navigation buttons remain visible on both views.

## Navigation and frontend resource

Kiosk Mode hides the header/sidebar and blocks the context menu
only when this dashboard's configuration is active. Existing dashboards and
account defaults remain unchanged. It is a usability feature, not an account
permission boundary; browser navigation and direct URLs remain possible.

The installed Home Assistant version is `2026.10.4`. Kiosk Mode `15.0.0` is
pinned according to its author's compatibility table, downloaded from the
official release, and checked against its published SHA-256 digest. It is
manually managed by this workflow, not registered as a HACS-managed download.
The file is `/config/www/proxmox-bootstrap/kiosk-mode-v15.0.0.js` and is loaded
as a local Lovelace module. Its configuration is scoped to the new dashboard.

The repository-owned `frontend/landet-cards.js` implements the small sensor
history/date dialogs and clips gallery. Its content-hashed local filename is
registered as a second Lovelace module and checked over HTTP. It contains no
credentials: history and Frigate event queries use the logged-in HA session.
Thumbnails are fetched with HA authentication; clips use short-lived signed
paths under the same HA origin. The viewer never needs the private Frigate
address. No new network service or background automation is installed.

Frontend source changes require an explicit prototype rollback/reapply, which
removes the owned old module before registering its replacement; this prevents
loading conflicting custom element versions. A browser hard refresh is needed
after replacing frontend resources. Other dashboards retain their configuration.

The previously absent `www` directory required one HA Core restart to register
the `/local` route. Config validation preceded that restart. Later apply or
rollback requires no restart when the module route is already available.
Frigate recording runs independently in CT200.

## Operator commands

Run from the repository as root on `nad9-1`, using the existing `HA_TOKEN` and
camera names in ignored `config/local.conf`:

```bash
bash scripts/step22c-landet-dashboard.sh --dry-run
bash scripts/step22c-landet-dashboard.sh --apply
bash scripts/step22c-landet-dashboard.sh --validate
bash scripts/step22c-landet-dashboard.sh --rollback
```

Preview reads HA state without writing files or resources. Apply creates only
the dedicated `landet-view` dashboard and its pinned resource, checks exact
readback, and compares other dashboard configurations before/after. A repeated
apply verifies identical state without rewriting it. A managed configuration
update retains the previous configuration in protected state and restores it
if update validation fails. Unmanaged edits are never overwritten. Unexpected edits or
unowned existing objects are preserved rather than overwritten.

Root-only ownership state is stored at
`/config/.proxmox-bootstrap/landet-dashboard.json`. Rollback removes only owned,
unchanged objects. If another dashboard has started using kiosk mode, the
shared module/resource is retained. No DNS record, Access policy, tunnel
ingress, account, or existing user preference is changed.

For owner recovery, open the usual HA URL or use:

<https://ha.ostmarken.se/landet-view/live?disable_km>

Refresh the browser after adding or removing frontend resources. Do not use
Kiosk Mode's query-string cache, which could hide navigation on other pages.

## Login decision after owner acceptance

If the screen is accepted, create a separate viewer account with read-only
permissions and no administrator privileges. Configure the actual device for
the owner: saved login, direct home-screen shortcut, and this dashboard as its
entry point. The older person should normally open one icon and see video.
Do not give them the owner's administrator credentials.

Read-only is still not camera-only data isolation. A normal HA user account
and hidden menus do not provide that boundary. Review permissions before any
invitation and choose a separate design if strict camera-only access is needed.

The current Access application is configured with a 24-hour session duration.
An HA saved login alone cannot remove later Cloudflare OTP challenges. Decide
how the viewer will reauthenticate before promising ongoing one-tap access.
Do not weaken the existing owner policy during this dashboard experiment.
The separate standalone viewer is now published; this HA prototype does not
manage its Access application, DNS or tunnel route.

## Acceptance

Eleven Python checks cover configuration, managed updates, failure restoration,
and rollback protections. Four JavaScript checks cover calendar/DST boundaries,
missing measurements, latest-ten filtering, and rejecting media URLs outside
the protected HA proxy. Real HA calls verified history and humidity samples,
recent events, and a sample signed MP4 response. The post-update integration
smoke test had zero failed tracks. Automated checks verify structure, resource hash/serving, entity availability,
idempotency, ownership protection, and rollback. They do not verify browser
rendering, touch behavior, or live video playback on the viewer's actual device.
The owner must confirm those before the next phase. Existing camera regression
checks remain mandatory after deployment.

```bash
PYTHONDONTWRITEBYTECODE=1 python3 scripts/step22c-landet-dashboard-tests.py
bash scripts/step10n-frigate-homeassistant-smoketest.sh
```

Frontend tests require Node 22+ on a development machine; no Node service or
host package is needed in production:

```bash
node scripts/step22c-landet-cards-tests.mjs
```

Reference: [Kiosk Mode installation and compatibility](https://github.com/NemesisRE/kiosk-mode).
