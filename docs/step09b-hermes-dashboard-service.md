# Step 09B - Hermes Dashboard Service

This step makes the Hermes dashboard persistent by creating a dedicated systemd service inside CT 220.

## Purpose

The Hermes gateway service handles Slack and messaging integrations.

The Hermes dashboard service is separate and only handles the optional Web UI.

Keeping these separate avoids mixing operational concerns.

## Service

```text
Service: hermes-dashboard.service
Container: CT 220
Run user: hermes
Port: 9119
Bind: 0.0.0.0
LAN URL: http://192.168.0.225:9119
```

## Scripts

Deploy:

```bash
bash scripts/step09b-hermes-dashboard-service.sh
```

Validate:

```bash
bash scripts/step09c-hermes-dashboard-validation.sh
```

## Manual status commands

From the Proxmox host:

```bash
pct exec 220 -- systemctl status hermes-dashboard.service --no-pager
pct exec 220 -- journalctl -u hermes-dashboard.service -n 80 --no-pager
pct exec 220 -- ss -ltnp | grep 9119
pct exec 220 -- curl -I http://127.0.0.1:9119/
```

From a LAN browser:

```text
http://192.168.0.225:9119
```

## Security notes

Do not expose the dashboard directly to the internet.

Use VPN or a secure tunnel later if remote access is needed.

The dashboard should remain optional. Slack mentions and the Hermes gateway are the primary operational path.

## Architecture decision

```text
Hermes CT 220
├── hermes-gateway.service
│     └── Slack and messaging platform integration
│
└── hermes-dashboard.service
      └── Optional Web UI on port 9119
```
