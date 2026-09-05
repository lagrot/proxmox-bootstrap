# Step 11 - Remote Access with Tailscale

This document records the remote-access setup for the `nad9-1` Proxmox homelab after moving to the `192.168.8.0/24` network.

## Current Network State

```text
Proxmox host:     nad9-1
LAN IP:           192.168.8.10/24
Gateway:          192.168.8.1
Tailscale IP:     100.66.43.1
Tailscale name:   nad9-1
```

Verified working:

```bash
ssh root@100.66.43.1
```

Proxmox Web UI:

- Tailscale: `https://100.66.43.1:8006`
- LAN: `https://192.168.8.10:8006`

## Current Service Addresses

| Service | Address |
|---|---|
| Proxmox host | `192.168.8.10` |
| Home Assistant | `192.168.8.105` |
| docker-core | `192.168.8.104` |
| mqtt-core | `192.168.8.103` |
| hermes-agent | `192.168.8.102` |

Service URLs:

| Service | URL |
|---|---|
| Proxmox UI | `https://192.168.8.10:8006` |
| Proxmox via Tailscale | `https://100.66.43.1:8006` |
| Home Assistant | `http://192.168.8.105:8123` |
| Frigate | `https://192.168.8.104:8971` |
| MQTT broker | `192.168.8.103:1883` |
| Hermes Web UI | `http://192.168.8.102:9119` |

## Cloudflare Tunnel Gateway

CT230 (`remote-gateway`) is an unprivileged Debian 13 container running
Cloudflare's official `cloudflared` package as a system service. The named
tunnel `nad9-remote-gateway` is remotely managed and currently healthy. It is
outbound-only: the Tele2 router has no inbound port forwarding, and no LAN
service is exposed until an explicit Cloudflare Access policy and hostname
route are created.

The read-only validation and smoke test is:

```bash
bash scripts/step22-cloudflare-gateway-validation.sh
```

It validates CT230, the local service, the Cloudflare API status, remote
configuration, and active tunnel connections without printing credentials.
The tunnel is intended for selected protected hostnames such as
`ha.ostmarken.se` and `landet.ostmarken.se`; Tailscale remains the preferred
administrative access path.

## Cloudflare API access setup

API secrets are stored only in the ignored `config/local.conf` file. Never
commit them or paste them into chat.

### DNS token

In Cloudflare, open **Manage account → Account API tokens → Create token** and
use the predefined **Edit zone DNS** template. Restrict its policy to the
specified domain `ostmarken.se`, choose a one-year expiration, leave client IP
filtering empty, and create the token. Store the one-time secret as:

```bash
CLOUDFLARE_API_TOKEN='secret-value'
```

### Cloudflared token

Create a second Account API token with **Start from scratch**. Use **Entire
Account** scope, search for `Cloudflare One Connector`, and select **Edit** on
the row **Cloudflare One Connector: cloudflared**. Do not select Read, WARP, or
the broader Cloudflare One Connectors permission. Choose a one-year expiration
and leave client IP filtering empty. Store its one-time secret as:

```bash
CLOUDFLARE_TUNNEL_API_TOKEN='secret-value'
```

Also store the Cloudflare account ID and the named tunnel ID:

```bash
CLOUDFLARE_ACCOUNT_ID='32-character-account-id'
CLOUDFLARE_TUNNEL_ID='tunnel-uuid'
CLOUDFLARE_GATEWAY_CT_ID='230'
```

Account API tokens are verified with the account-specific endpoint:

```text
GET /client/v4/accounts/{ACCOUNT_ID}/tokens/verify
```

The gateway validation script performs this work without printing either
secret:

```bash
bash scripts/step22-cloudflare-gateway-validation.sh
```

See Cloudflare's [API token documentation](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
and [Tunnel API documentation](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel-api/)
for the current permission names and endpoints.

## Tailscale Access Model

Current devices:

| Device | Tailscale IP | Tag |
|---|---|---|
| `rpi-1` | `100.123.116.90` | `tag:trusted` |
| `hermes-iot` | `100.89.33.12` | `tag:iot` |
| `nad9-1` | `100.66.43.1` | `tag:server` |

Intended access model:

| Source | Destination |
|---|---|
| `rpi-1` / `tag:trusted` | Full access |
| `hermes-iot` / `tag:iot` | Only `tag:iot` destinations |
| `nad9-1` / `tag:server` | No access to `hermes-iot` |
| `group:admin` | Full access |

Current final Tailscale ACL policy:

```json
{
  "groups": {
    "group:admin": ["lasse.grotell@gmail.com"]
  },

  "tagOwners": {
    "tag:iot": ["group:admin"],
    "tag:trusted": ["group:admin"],
    "tag:server": ["group:admin"]
  },

  "acls": [
    {
      "action": "accept",
      "src": ["group:admin"],
      "dst": ["*:*"]
    },
    {
      "action": "accept",
      "src": ["tag:trusted"],
      "dst": ["*:*"]
    },
    {
      "action": "accept",
      "src": ["tag:iot"],
      "dst": ["tag:iot:*"]
    }
  ],

  "ssh": [
    {
      "action": "check",
      "src": ["group:admin"],
      "dst": ["tag:iot", "tag:trusted", "tag:server"],
      "users": ["autogroup:nonroot", "root", "count"]
    },
    {
      "action": "accept",
      "src": ["tag:trusted"],
      "dst": ["tag:iot", "tag:server"],
      "users": ["autogroup:nonroot", "root", "count"]
    }
  ],

  "tests": [
    {
      "src": "tag:trusted",
      "accept": ["100.89.33.12:22", "100.66.43.1:22"]
    },
    {
      "src": "tag:iot",
      "deny": ["100.123.116.90:22", "100.66.43.1:22"]
    },
    {
      "src": "tag:server",
      "deny": ["100.89.33.12:22"]
    }
  ]
}
```

## SSH Client Config

Windows SSH config path:

```text
C:\Users\count\.ssh\config
```

Working config:

```sshconfig
Host github.com
    HostName github.com
    IdentityFile C:\Users\count\.ssh\id_ed25519_github
    IdentitiesOnly yes

Host rpi-1
    HostName 192.168.0.36
    User count
    IdentityFile C:\Users\count\.ssh\id_rsa
    IdentitiesOnly yes

Host nad9-1
    HostName 100.66.43.1
    User root
    ProxyJump rpi-1
    IdentityFile C:\Users\count\.ssh\id_rsa
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

Connection path:

```text
Windows / VS Code
  -> rpi-1 at 192.168.0.36
  -> nad9-1 at 100.66.43.1
```

Test:

```bash
ssh nad9-1 'echo OK'
```

Expected:

```text
OK
```

## VS Code Remote SSH

VS Code Remote SSH works against:

```text
nad9-1
```

Open folder:

```text
/root/proxmox-bootstrap
```

Important fix applied: `/root/.bashrc` on `nad9-1` must not print banners, `fastfetch` output, or Tailscale status during non-interactive SSH/SCP sessions.

A guard was added before prompt/banner output:

```bash
# Stop here for non-interactive shells.
# This prevents SSH/SCP/VS Code Remote-SSH from receiving banner output.
case $- in
    *i*) ;;
    *) return ;;
esac
```

This fixed the VS Code/SCP error:

```text
Received message too long
Ensure the remote shell produces no output for non-interactive sessions.
```

## rpi-1 Resource Check

`rpi-1` is an old Raspberry Pi 3B.

Observed steady state after boot:

| Metric | Value |
|---|---|
| `tailscaled` CPU | `5.3-5.4%` |
| `tailscaled` RAM | About `65 MiB` RSS |
| Load average | `0.22, 0.20, 0.13` |

Conclusion:

- Tailscale is acceptable on `rpi-1` for jump-host use.
- Do not use `rpi-1` as the VS Code target.
- Use `rpi-1` only as the SSH jump host.
- Use `nad9-1` as the actual VS Code remote target.

## Network Move Notes

The Proxmox host network config was changed from:

```text
address 192.168.0.223/24
gateway 192.168.0.1
```

to:

```text
address 192.168.8.10/24
gateway 192.168.8.1
```

Current `/etc/network/interfaces` relevant section:

```text
auto vmbr0
iface vmbr0 inet static
        address 192.168.8.10/24
        gateway 192.168.8.1
        bridge-ports nic0
        bridge-stp off
        bridge-fd 0
```

DNS is managed by Tailscale on the Proxmox host:

```text
/etc/resolv.conf generated by tailscale
nameserver 100.100.100.100
```

## Validation Commands

Run on `nad9-1`:

```bash
ip route
ping -c 3 192.168.8.1
ping -c 3 1.1.1.1
curl -k -I --max-time 10 https://127.0.0.1:8006
```

Run from `rpi-1`:

```bash
ssh root@100.66.43.1
curl -k --connect-timeout 5 --max-time 10 https://100.66.43.1:8006/
```

Check service IPs:

```bash
pct list
qm list
qm agent 100 network-get-interfaces
pct exec 200 -- hostname -I
pct exec 210 -- hostname -I
pct exec 220 -- hostname -I
```

Check services:

```bash
curl -s -o /dev/null -w 'Home Assistant: %{http_code}\n' --max-time 10 http://192.168.8.105:8123
curl -k -s -o /dev/null -w 'Frigate: %{http_code}\n' --max-time 10 https://192.168.8.104:8971
nc -vz -w 5 192.168.8.103 1883
```
