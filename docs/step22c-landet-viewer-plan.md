# Landet viewer: decisions and acceptance plan

## Accepted scope and current state

**TV-fönstret** is published at **https://landet.ostmarken.se**. The owner has
accepted the design and authenticated desktop opening/live view. See the
[deployment guide](step22d-landet-deployment.md) for operations and rollback.

- Computer-first, responsive for tablet and phone, with Swedish labels and
  large readable controls for a viewer unfamiliar with Home Assistant.
- Two selectable live cameras with pause and fullscreen. Camera models remain
  labelled Kamera 1 / Tapo C200 and Kamera 2 / Tapo C320WS until placement is final.
- Up to **nine latest completed retained clips**, newest first. The owner chose
  a spacious 3 × 3 desktop grid over the original twelve-clip filmstrip. Tablet
  uses two columns and phone one; fewer retained clips produce fewer entries.
  Play/seek/fullscreen/close work in a dedicated player. “Visa fler”, recording
  date browsing and detailed timelines are deferred.
- Four temperatures: **Kök**, Sovrum, Örnnästet, Utomhus. Kök is the renamed
  Vardagsrum display label; the underlying sensor and history are unchanged.
  Three indoor humidities; no outdoor humidity is invented.
- Rolling 24-hour previews and enlarged temperature/humidity graphs, with
  calendar selection in Europe/Stockholm and DST-aware day boundaries.
  History is bounded to ten calendar days and actual HA recorder availability.
- Bounded automatic refresh, explicit missing/stale/error states, release of
  media on close/hidden pages, reconnect on return, and keyboard focus recovery.
- No HA/Frigate administration, recording switches, unrelated entities or
  general-purpose proxy. Keep event-only recording and retention unchanged.

## Architecture decisions

A bespoke viewer provides control over usability and access scope without
relying on hiding Home Assistant navigation. The working HA prototype remains
reference/fallback; further HA dashboard development is paused.

Zola 0.23.6 generated the offline visual studies. It is fast and self-contained,
but a small dynamic viewer still needs a backend. Production serves the selected
thin HTML/CSS/JavaScript shell directly; Zola and Rust are not runtime
requirements. Keeping the shell simple avoids a duplicate build pipeline.
No heavy frontend framework or external runtime CDN/font dependency is needed.

Three structurally different studies informed the choice: a schematic **Huset**,
a camera-focused **TV-fönstret**, and a chronological **Dagboken**. The selected
experience emphasizes one large camera with explicit channel choices, climate
summary and expandable climate panel. The recordings area was subsequently
changed from a horizontal filmstrip to a nine-entry responsive grid.

CT240 is a separate unprivileged LXC. A small Python read-only API, nginx and a
private go2rtc relay serve one origin. The browser receives no HA token, camera
credentials or private upstream addresses. It never requests HA or Frigate
administration endpoints directly. No second recording store or new database
is introduced. CT230 retains only its outbound gateway role; CT200 retains
Frigate and its working recording/detection configuration.

The main streams are relayed without transcoding; the earlier MJPEG fallback
remains available for local development. Clips use Frigate's existing HLS VOD,
with a pinned local hls.js light 1.6.16 on MSE browsers or native HLS. The event
MP4 endpoint's lack of byte ranges motivated HLS rather than downloading entire
clips to browser memory. All manifests/segments remain on the protected origin.

## Protection and operations

A dedicated exact-owner Cloudflare Access OTP policy uses a 24-hour session.
The viewer needs no HA login. cloudflared validates the dedicated audience;
the backend separately validates signed application tokens, issuer, audience,
expiry/issued-at, subject and owner email. Never trust an identity header alone.
Only the gateway/localhost can reach the nginx origin; upstream credentials
remain in protected service configuration.

Camera/room aliases, methods, date windows, media IDs, playlist references and
routes are allowlisted. Server-issued clip IDs expire and source ownership /
retention are rechecked. Concurrency, reads, media sizes and timeouts are bounded.
Application deployment and public route publication are separate repeatable
workflows with non-mutating previews and rollback. Public checks require an
Access redirect; TLS validation is never disabled. See the deployment guide for
current commands and the distinction between application and DNS/route rollback.

## Delivery evidence

1. Offline visual studies and three viewport sizes passed; the owner selected
   TV-fönstret. Fictional images, values and simulated clip playback are labelled.
2. A one-camera/one-clip/one-thermometer integration proof established real video,
   playback/seek and history, followed by owner Windows testing. HQ main streams
   and HLS VOD replaced the low-quality/full-clip-buffering proof approaches.
3. Both cameras, all readings/history and the nine-clip grid pass local Chromium
   checks; the owner accepted the complete layout and the Kök display name.
4. CT240 services, initial OS baseline, reboot/startup, unchanged-release no-op,
   real application/config rollback, origin denial and JWT boundaries pass.
5. The confirmed DHCP reservation and protected public route are deployed.
   Machine external denial, actual route-only rollback and automatic managed
   DNS/route rollback pass. Existing HA Cloudflare regression validation passes.
6. The owner opened the authenticated public site on desktop and accepted its
   appearance/live view. Full public mobile-data playback/session acceptance is
   not independently confirmed and must not be reported as verified.

## Follow-up acceptance

- Public camera switching, fullscreen, clip play/seek and all history on the
  intended mobile/tablet device and mobile data; Safari/iOS behavior.
- Screen-lock/network recovery, long-running playback and measured latency.
  HQ live currently reconnects every 55 seconds; seamless transport remains work.
- Session expiry/re-authentication and easy bookmarked access for the intended
  older viewer. Do not promise permanent one-tap access or extend sessions silently.
- CT240 audit/update/recovery integration and observation before removing the
  retained OS-baseline rollback snapshot. OS/rootfs rollback is not tested.
- Additional viewer identities/policy changes and “Visa fler” are separate scope.

Correct physical camera placement before face recognition, zones, masks or final
notification tuning. Preserve both existing camera baselines.

## References

- [Zola overview](https://www.getzola.org/documentation/getting-started/overview/)
- [Reddit: floorplan/tablet dashboard](https://www.reddit.com/r/homeassistant/comments/1ftror2/)
- [StratoBuilds: visual floorplans](https://stratobuilds.com/project/home-assistant-dashboard-floorplans-generated-by-chatgpt/)
- [HomeAutoCentral: task/room-based dashboard design](https://homeautocentral.com/home-assistant-dashboard-guide/)
- [Cloudflare token validation](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/)
