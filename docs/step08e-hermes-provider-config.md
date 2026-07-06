
i# Step 08E - Hermes Provider / Model / API-Key Configuration

## Purpose

Configure Hermes Agent provider, model, and API credentials inside CT 220.

This step is intentionally manual because it involves secrets.

Do not store API keys in:

- repo scripts
- documentation
- git
- shell history if avoidable
- shared logs

## Current Hermes state

```text
CT: 220
Hostname: hermes-agent
User: hermes
Hermes CLI: /usr/local/bin/hermes
Hermes home: /home/hermes/.hermes
Service: hermes-gateway.service
Service state before config: disabled and inactive
```

## Enter Hermes CT

From the Proxmox host:

```bash
pct enter 220
```

Switch to the Hermes user:

```bash
su - hermes
```

Confirm Hermes works:

```bash
PATH=/usr/local/bin:/usr/bin:/bin hermes --help
```

## Useful Hermes commands

Hermes exposes these relevant commands:

```bash
hermes setup
hermes model
hermes auth
hermes config
hermes doctor
hermes gateway
hermes status
```

Use command-specific help before changing config:

```bash
hermes setup --help
hermes model --help
hermes auth --help
hermes config --help
hermes doctor --help
hermes gateway --help
```

## Recommended first configuration path

Use the interactive setup wizard:

```bash
hermes setup
```

If prompted for provider, select the intended provider.

For this homelab, current intended provider is:

```text
Provider: OpenRouter
```

The previously intended model architecture is:

```text
Main planner: DeepSeek V4 Pro
Tool executor: NVIDIA Nemotron-3 Super 120B A12B
Research/web: Kimi K2.6
```

Do not paste API keys into scripts.

## Auth / credential handling

Check auth help:

```bash
hermes auth --help
```

If Hermes supports adding the OpenRouter credential with auth:

```bash
hermes auth add openrouter
```

If Hermes setup asks for the API key interactively, enter it manually there.

## Config inspection

View current config:

```bash
hermes config
```

Edit current config if needed:

```bash
hermes config edit
```

Hermes help says the persistent provider lives in `config.yaml` under:

```text
model.provider
```

## Validation after config

Run:

```bash
hermes doctor
```

Run:

```bash
hermes status
```

Optional one-shot smoke test:

```bash
hermes -z "Reply with exactly: Hermes provider test OK"
```

Expected result:

```text
Hermes provider test OK
```

## Start gateway only after config works

Exit back to root if needed:

```bash
exit
```

From inside CT 220 as root, or from Proxmox using `pct exec`, enable and start only after provider validation works.

From Proxmox host:

```bash
pct exec 220 -- systemctl enable hermes-gateway.service
pct exec 220 -- systemctl start hermes-gateway.service
pct exec 220 -- systemctl status hermes-gateway.service --no-pager
```

## Logs

From Proxmox host:

```bash
pct exec 220 -- journalctl -u hermes-gateway.service --no-pager -n 80
```

As hermes user:

```bash
hermes logs
hermes logs errors
```

## Next step

After this is configured and the gateway service is started:

```text
Step 08F - Hermes running service validation
```

Step 08F should validate:

```text
CT 220 running
Hermes CLI works
Provider config exists
No obvious secrets in repo
hermes doctor result
hermes-gateway.service enabled
hermes-gateway.service active
Recent service logs do not show obvious startup errors
```

