# Protected Landet deployment

CT 240 `landet-viewer` is an unprivileged Debian 13 LXC: one core, 512 MiB RAM,
256 MiB swap and an 8 GiB rootfs. Its current DHCP address is **192.168.8.124**,
MAC **BC:24:11:DA:AC:AB**. The router DHCP reservation is confirmed.
It has no media archive/database; HA and Frigate remain the sources of truth.

**Published address: https://landet.ostmarken.se**. A separate owner-only
Cloudflare Access application protects it. Automated external unauthenticated
and forged-assertion requests redirect to the expected HTTPS login domain.
The owner has accepted authenticated desktop access/live view and the design.
Public mobile-data, Safari/iOS and session/recovery acceptance remain follow-up.
The existing `ha.ostmarken.se` application/route is unchanged.

## Architecture

- A separate `landet` system user runs the viewer backend and private go2rtc
  relay. systemd starts both at boot with resource limits, restricted filesystem
  access, no capabilities, and no new privileges.
- Unused SSH and Postfix services inherited from the template are disabled.
  Nginx listens on CT240 port 8080, allowing only CT230's discovered LAN address
  and localhost. It proxies to backend loopback port 8765 without buffering
  media. Direct LAN clients receive 403; no admin service is proxied.
- The relay HTTP API listens only on loopback 1986; RTSP/WebRTC listening is
  disabled. Selected main streams are opened on demand without transcoding.
- The backend is launched with `--require-access`, so missing/misconfigured
  credentials cannot silently turn production into the local SSH mode.
- Every viewer/media request requires a signed RS256 Cloudflare application
  token with the expected issuer, dedicated Landet audience, expiry/issued-at,
  application type, non-empty subject and exact owner email. Other app tokens,
  unsigned/forged/expired tokens and other users are denied. `healthz` exposes
  only readiness/mode, never upstream data. Unknown keys/key outages fail closed;
  signing-key refreshes are bounded. Cloudflare signing-key retrieval works.
- The separate Landet Access application reuses the existing OTP provider and
  verified owner email, with a 24-hour session. No new viewer identity has been
  invited. A later viewer policy/session change needs its own usability review.

## Commands on nad9-1

Run from `/root/proxmox-bootstrap`. Credentials remain in ignored
`config/local.conf`; generated Access metadata is root-only under
`/var/lib/proxmox-bootstrap/landet/`.

```bash
bash scripts/step22d-landet-access.sh --dry-run
bash scripts/step22d-landet-access.sh --apply
bash scripts/step22d-landet-deploy.sh --dry-run
bash scripts/step22d-landet-deploy.sh --apply
bash scripts/step22d-landet-deploy.sh --validate
```

All commands above were exercised. Access dry-run performs only GET requests
and writes no state; an isolated test enforces this. Access apply creates or
strictly verifies only the separate app/owner OTP policy. It does not change
shared identity-provider settings, HA, DNS or tunnel ingress.

Deployment preview reads guest/config state without creating anything. Apply
creates/reuses only the explicitly managed unprivileged CT240, installs missing
Debian dependencies, discovers HA/Frigate/gateway IPs, installs immutable
release files, and writes protected runtime configuration. The relay binary is
reused from the pinned Frigate image. Camera credentials remain in a root-owned
0640 relay file readable by the service group; the HA token stays in a root-only
systemd environment file. Neither enters source archives, logs or Git.
Existing dependencies are not upgraded by deployment; OS maintenance remains a
separate deliberate action. CT240 is included in the weekly audit and recovery
backup; see `docs/step24-landet-operations.md`. It is also a controlled
Debian Security installation target; see `UPDATE-QUICK-GUIDE.txt`. Its initial Debian stable
base was fully patched after a native Proxmox snapshot; post-update reboot,
service validation and a zero-pending-upgrades simulation pass. Keep snapshot
`landet-before-os-baseline` for observation; OS/rootfs rollback was not exercised.

A content/configuration-identical apply preserves the running backend PID.
Changed releases retain the prior code, runtime configuration, nginx config and
service units. Failed post-install validation attempts rollback. Creation is
not destructive toward other guests; an unexpected CT240 identity is rejected.
Proxmox's non-secret extraction directory needs an ordinary umask; secret
creation retains umask 0077. Serialized description newlines are normalized for
the exact managed-container identity check.

## Rollback

```bash
bash scripts/step22d-landet-deploy.sh --rollback
bash scripts/step22d-landet-deploy.sh --validate
```

A real prior-release/configuration rollback, validation, and redeployment were
exercised while unpublished. With no prior release, rollback disables/stops the
initial viewer/relay/nginx services and retains CT240 for inspection/rebuild;
validation is then expected to fail until reapply. This is an application/config
rollback, **not a package/rootfs downgrade** and does not remove an Access app,
DNS or tunnel route. For DNS/tunnel rollback, use the separate publication workflow below. If
rolling back an initial deployment by stopping its services, unpublish first.

Repeat apply without restart and an actual CT240 reboot/startup/revalidation
passed. Direct LAN origin denial (403), CT230 missing-token denial (401),
forged-token rejection and the actual signed-owner HTTP boundary passed.
Validation also reads all configured upstream states/history, nine retained
clips and both camera feeds from CT240 using only server-side credentials.
Both existing camera processing baselines must remain healthy.

## Checks and remaining gates

```bash
python3 viewer/tests/proof-server.py
python3 viewer/tests/access-setup.py
python3 viewer/tests/access.py
python3 viewer/tests/access-http.py
```

Host JWT tests need Debian PyJWT/cryptography (an isolated temporary package path
was used during development; CT240 has both dependencies). Fifteen existing
viewer boundary tests, five JWT tests, two read-only setup tests and a signed
HTTP-boundary test pass. No private media is saved by these tests.

Before public use:

1. Keep the confirmed viewer DHCP reservation and existing upstream/gateway
   reservations. Reapply if upstream/gateway addressing changes.
2. CT240 audit/recovery integration is documented in `docs/step24-landet-operations.md`;
   manual Debian Security patching follows `UPDATE-QUICK-GUIDE.txt`. Its initial OS baseline
   is now current; future maintenance remains deliberate and separate from
   application deployment.
3. Publication is complete; use the validated transaction below for checks and
   rollback. It preserves other routes and revalidates the exact-owner policy.
4. After guarded publication, perform an external unauthenticated-denial check
   and the owner's authenticated mobile-data browser test: both streams,
   fullscreen, clip play/seek, all readings/history, session expiry and recovery.
   No actual Cloudflare-signed owner playback through CT240 is claimed yet.
5. Review live latency/reconnect behavior, Safari/iOS/touch devices and sign-in
   usability before inviting the intended older viewer.

References: [Cloudflare token validation](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/),
[session management](https://developers.cloudflare.com/cloudflare-one/access-controls/access-settings/session-management/).


## Protected publication and rollback

```bash
bash scripts/step22d-landet-publish.sh --dry-run
bash scripts/step22d-landet-publish.sh --apply
bash scripts/step22d-landet-publish.sh --validate
```

These operator commands were exercised. Preview validates the private services,
upstream data, dedicated app audience, exact-owner OTP policy, 24-hour session,
DNS ownership and tunnel configuration using read-only calls. Apply installs
only a dedicated Landet ingress and a managed proxied CNAME. The ingress has
`originRequest.access.required=true`, the team name and dedicated AUD tag;
cloudflared validates the JWT in addition to the backend. Existing ingress
rules, catch-all and other settings remain unchanged.

A route-only add/readback/removal pilot (`--test-route`) passed before DNS was
created. That mode refuses a published hostname. Seven isolated transaction
tests cover no-op repeated apply, dry-run, conflicting DNS/routes, failed
external verification and preservation of unrelated concurrent routes.
Real automatic route/DNS rollback was exercised during failed initial external
checks. No other ingress or Access app was removed.

The external probe uses authoritative DNS to avoid recursive negative caches,
then connects to a public edge address with SNI and full certificate validation
for the actual hostname. Browser-like unauthenticated requests with a forged
assertion to the page, climate, clip list and live endpoint must redirect to the
expected HTTPS Cloudflare login domain. No token/cookie or private content is
logged. Some recursive resolvers can briefly retain an earlier NXDOMAIN.

To unpublish only this managed viewer:

```bash
bash scripts/step22d-landet-publish.sh --rollback
```

This removes only the matching managed CNAME and exact Landet route, preserving
Access, CT240 and all other ingress. It can run even if CT240 is stopped. It
refuses to delete a changed/unowned record or route. It does not overwrite an
old full tunnel configuration over concurrent changes.

The owner accepted desktop opening/live view. Full public playback on mobile
data, session expiry usability and screen-lock recovery remain follow-up;
machine denial tests are not a substitute for those checks.
