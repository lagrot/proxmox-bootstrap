# Hermes Agent KISS Setup Notes

## Purpose

This document records the current simple working Hermes Agent setup for the Proxmox homelab.

The goal is to keep Hermes usable and avoid over-complicating the setup.

## Current decision

Keep Hermes simple:

```text
Hermes CT 220
├── Hermes runs as user: hermes
├── Provider: OpenRouter
├── Gateway: systemd service
├── Slack: @nad9hermes mention works
└── Web UI: not used for now
```

## Current working state

```text
CT ID:        220
Hostname:     hermes-agent
Hermes user:  hermes
Hermes home:  /home/hermes/.hermes
Base dir:     /opt/hermes
Service:      hermes-gateway.service
Slack bot:    nad9hermes
```

## Verified

The following is verified:

- Hermes CLI works.
- OpenRouter provider works.
- Hermes one-shot model test works.
- Hermes gateway service is active.
- Hermes gateway service starts at boot.
- Slack mention integration works.

Slack test:

```text
Lasse:       hello @nad9hermes
nad9hermes: Hello! How can I help you today?
```

## Provider

Current provider:

```text
Provider: OpenRouter
Default model: nvidia/nemotron-3-ultra-550b-a55b:free
```

Smoke test command:

```bash
hermes -z "Reply with exactly: Hermes provider test OK"
```

Expected output:

```text
Hermes provider test OK
```

## Admin model

Use the Proxmox host as the entry point.

From Proxmox host:

```bash
pct enter 220
```

Then inside CT 220:

```bash
su - hermes
```

For one-shot commands from Proxmox host:

```bash
pct exec 220 -- runuser -l hermes -c 'hermes gateway status'
```

## Daily commands

Check Hermes:

```bash
hermes doctor
```

Check gateway:

```bash
hermes gateway status
```

Restart gateway:

```bash
sudo hermes gateway restart --system
```

Check service status:

```bash
sudo systemctl status hermes-gateway.service
```

View gateway logs:

```bash
sudo journalctl -u hermes-gateway.service --no-pager -n 80
```

## Service model

Keep the gateway as a system-wide service:

```text
hermes-gateway.service
```

Do not switch to a per-user systemd service.

Reason:

```text
This is a dedicated Proxmox LXC server-style deployment.
The system-wide service starts reliably when CT 220 boots.
It is easier to validate and manage from the Proxmox host.
```

## Sudo model

Hermes runs as the `hermes` user, not root.

The `hermes` user has limited sudo permissions for Hermes gateway management only.

This is intentional:

- Do not give Hermes full root access.
- Do not give broad sudo access.
- Only allow specific gateway commands.

Useful allowed commands:

```bash
sudo systemctl status hermes-gateway.service
sudo systemctl restart hermes-gateway.service
sudo systemctl start hermes-gateway.service
sudo systemctl stop hermes-gateway.service
sudo systemctl restart hermes-gateway
sudo hermes gateway restart --system
sudo hermes gateway start --system
sudo hermes gateway stop --system
sudo hermes gateway status --system
sudo journalctl -u hermes-gateway.service --no-pager -n 80
```

## Slack

Slack integration is working with mentions.

Use:

```text
@nad9hermes hello
```

Current Slack channel used for testing:

```text
nad9-proxmox
```

For now, use mentions only.

## Known Slack follow-up

Slack warned that Hermes installed generic slash commands such as `/undo`, which may conflict with another app named Moss.

This is a later cleanup task.

Later cleanup:

Remove or disable generic Hermes slash commands such as:

- `/undo`
- `/retry`
- `/new`
- `/start`
- `/stop`
- `/help`
- `/update`
- `/version`
- `/model`

Keep:

- `@nad9hermes` mentions.

Optional later:

- `/nad9hermes`

Do not fix this now unless it becomes a real problem.

## Web UI decision

Do not use Hermes Web UI for now.

Reason:

```text
The dashboard required extra authentication configuration.
The basic-auth login path produced an internal server error.
The Web UI is not needed for the current working setup.
```

Do not run:

```bash
hermes dashboard
```

Do not expose:

```text
Port 9119
```

Cleanup if needed:

```bash
hermes dashboard --stop
```

## What not to do now

Do not continue expanding Hermes now.

Avoid:

- No Web UI.
- No per-user service conversion.
- No more Slack app rebuilds unless needed.
- No doctor-warning cleanup unless it blocks real use.
- No OpenAI OAuth/Codex setup right now.
- No xAI/web-search API key cleanup right now.
- No slash-command cleanup right now.

## Current stopping point

Hermes is good enough and usable.

Current milestone:

| Step | Description | Status |
|---|---|---|
| Step 08E | Hermes provider/API config | verified |
| Step 08F | Hermes gateway service | verified |
| Step 09A | Slack mention integration | verified |

## Recommended next project step

Stop Hermes changes here.

Next recommended work:

```text
Home Assistant + MQTT + Frigate integration
```

Then:

```text
Add first Frigate camera
```

## Security notes

Do not expose Hermes services directly to the internet.

Do not expose:

- Hermes dashboard.
- Hermes gateway internals.
- Proxmox.
- Home Assistant.
- Frigate.
- MQTT.

When the server later moves to the country house with 4G/5G router, use VPN or a secure tunnel for remote access.
