# TV-fönstret: complete local viewer

Current entry point: `scripts/step22c-landet-viewer.sh`. It supersedes the
one-camera proof launcher. The original visual mockups remain offline samples;
this viewer uses real data and its own HTML/JavaScript frontend under
`viewer/proof/static/`. Production frontend/build packaging remains separate.

## Start and review

From `/root/proxmox-bootstrap` on nad9-1:

```bash
bash scripts/step22c-landet-viewer.sh --dry-run
bash scripts/step22c-landet-viewer.sh --check
bash scripts/step22c-landet-viewer.sh --serve-hq
```

Preview discovers guest addresses but starts no processes or media requests.
Check reads the four thermometers/history, available clips, and both MJPEG
sources, printing only sanitized results. Serve starts a foreground loopback
server plus a temporary private restream process. No installed service, new
guest, package install, Frigate configuration change, restart, or Cloudflare
route is involved. Ctrl+C stops the viewer and removes its owned restream and
private temporary files. Actual occupied ports are rejected; immediate restart
after a closed connection is supported. `--serve` provides low-resolution MJPEG
instead, without the temporary relay. Bash and Python standard library are the
only host dependencies; hls.js is served locally with its license.

Stop the earlier one-camera test with Ctrl+C before starting the full viewer.
On the Windows computer, use **PowerShell**:

```powershell
ssh -t -L 8765:127.0.0.1:8765 root@nad9-1 "cd /root/proxmox-bootstrap && bash scripts/step22c-landet-viewer.sh --serve-hq"
```

Keep the terminal open and browse to **http://127.0.0.1:8765**. Ctrl+C stops the
remote process; exit SSH to close the forward. The underlying launcher was
tested on nad9-1. The owner tested and accepted the Windows SSH prototype. This development
command is separate from the published Cloudflare service.

## Included behavior

- Camera/channel selection: Tapo C200 and Tapo C320WS, one active main stream
  at a time. Local Chromium decoded 1920×1080 and 2560×1440 respectively.
  Pause, fullscreen, return from a hidden tab, and initial-failure retry are
  provided. HQ live transport reconnects every 55 seconds with a server cap of
  60 seconds; seamless indefinite playback and measured latency remain open.
- Up to nine newest completed retained events across both cameras, shown in
  a spacious grid (three columns on desktop, two on tablet, one on phone), deduplicated
  and sorted newest first. Fewer available clips produce fewer entries, including
  a valid empty state. Selecting a clip opens a closeable HLS video dialog with
  native play/seek/fullscreen controls. No whole-clip download or second archive.
- Four temperatures, three indoor humidity readings; outdoor humidity is absent.
  Kök, Sovrum, Örnnästet, and Utomhus are mapped to exact allowlisted
  entities in `server.py`. Current readings refresh every minute. Unavailable
  data stays missing; old sensor-change timestamps are flagged.
- The climate button expands four room cards and recent 24-hour temperature
  previews. Room selection opens full temperature/humidity graphs, either rolling
  24 hours or one selected calendar date in Europe/Stockholm. Historical dates
  are bounded to ten calendar days; HA recorder determines actual availability.
  Null values split curves. DST boundaries use actual timezone-aware instants.
- Clip metadata and previews refresh once per minute; unchanged clip grids retain
  keyboard focus. Escape/close releases the clip player and restores focus.
  Hidden pages stop live media and pause clip downloads; returning reconnects.

Camera labels are provisional Kamera 1 and Kamera 2, with actual models shown.
No location such as garden/entrance is inferred for the real camera feeds.

## Access boundary and limits

This is a trusted-operator, loopback/SSH viewer, **not production authentication**.
Do not bind it publicly or forward it via Cloudflare. HA_TOKEN is read from
protected local configuration and stays server-side. The relay's private camera
URLs remain only in its mode-0600 temporary config. Its HTTP API is loopback-only;
RTSP/WebRTC listening is disabled. Only selected sources are opened on demand.

Fixed camera routes allow only c200/c320. Room/history requests accept only four
room aliases, one bounded date or `24h`, and no extra fields. Clip metadata is
capped at nine. Media access is limited to recently server-issued clip IDs
(15-minute validity, maximum 48 IDs so existing players survive list refresh),
with source camera and retention rechecked. HLS references must be allowlisted
sibling files. Unknown paths, entities, upstream URLs, writes, foreign Host or
Origin and cross-site fetches are rejected. No CORS is enabled; no upstream
URLs, credentials, raw errors or private captures are emitted. JSON, media,
timeouts, request threads and live viewers are bounded. No private media is
saved by the test suite. Production identity, credential scope, origin isolation,
runtime service user, deployment/rollback and external denial checks remain open.

## Verification

```bash
python3 viewer/tests/proof-server.py
node viewer/tests/full-viewer.cjs
```

The first command runs fifteen isolated boundary/failure tests. The second is
an opt-in live Chromium smoke check with Node and Playwright installed as
described in `viewer/README.md`. Set `PROOF_ORIGIN` to the running local origin.
It covers both real main streams, clips from both cameras playing and seeking,
all room histories, outdoor humidity absence, dates, responsive widths,
pause/reconnect, invalid resource requests and same-origin traffic.

For QA alongside another operator's session:

```bash
LANDET_PROOF_PORT=8766 LANDET_RELAY_PORT=1987 bash scripts/step22c-landet-viewer.sh --serve-hq
```

Use `PROOF_ORIGIN=http://127.0.0.1:8766` for the browser test. QA does not stop
another operator's session. Both extra listeners and private files are removed
on normal termination. These host-side commands have been exercised.

Windows full-viewer acceptance, Safari/iOS, physical touch devices, screen-lock
recovery, measured latency and production Cloudflare access remain unverified.
See `docs/step22c-landet-viewer-plan.md` for delivery gates.
