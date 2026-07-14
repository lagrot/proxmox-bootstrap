Proxmox Homelab Bootstrap Project Summary

We are working on a Proxmox homelab bootstrap project on host nad9-1.

This summary is intended to be pasted into a fresh ChatGPT conversation so the project can continue without losing context.

Working style and preferences

User wants a modular, production-style Bash framework.

Principles:

reliability

readability

reusability

safety

debuggability

idempotency where practical

Prefer one script or project step at a time.

During troubleshooting, give one command at a time.

During normal build or verify mode, full command sequences are OK.

Avoid large fragile sed edits for Bash blocks unless the file layout is known.

Prefer safe scripted edits using Python patchers when automation is useful.

Keep secrets, API keys, tokens, and .env files out of Git.

Use validation scripts after deployment scripts.

Documentation should go under docs/.

Use Proxmox-native commands:

pct

qm

Proxmox Web UI

Use pct enter and pct exec instead of installing SSH into every LXC.

Keep the setup simple.

Avoid “cool” complicated configs unless needed.

Host and hardware

Host:

Hostname: nad9-1
Proxmox IP: 192.168.0.223
Proxmox VE: 9.2.3
Kernel seen: 7.0.14-3-pve

Hardware:

Minisforum NAD9
CPU: 12th Gen Intel Core i9-12900H
GPU: Intel iGPU
RAM: initially 16 GiB
Storage:
  - NVMe 512 GB for Proxmox system / VM / LXC storage
  - SATA SSD 512 GB dedicated to Frigate media
Coral: USB Coral TPU

Network speed test on current Stockholm/fiber connection:

Download: 865.64 Mbit/s
Upload:   545.52 Mbit/s
Ping:     9.7 ms

Future note:

Server may later move to a country house with 4G/5G router.

Do not expose Proxmox, Home Assistant, Frigate, MQTT, Hermes, or Hermes Web UI directly to the internet.

Use VPN or secure tunnel later.

Current target architecture

Proxmox Host nad9-1
IP: 192.168.0.223

├── VM 100: Home Assistant OS
│     └── Home Assistant Core / Supervisor
│
├── CT 200: docker-core / frigate-core
│     └── Docker Compose
│           └── Frigate
│                 ├── Intel iGPU decode acceleration
│                 ├── USB Coral TPU object detection
│                 └── /mnt/frigate recordings/snapshots/exports
│
├── CT 210: mqtt-core
│     └── Mosquitto MQTT native Debian package
│
└── CT 220: hermes-agent
      └── Hermes Agent gateway / optional Web UI

Current addresses:

Proxmox host:      192.168.0.223
Home Assistant:   http://192.168.0.218:8123
Frigate:          https://192.168.0.224:8971
MQTT broker:      192.168.0.217:1883
Hermes CT:        192.168.0.225
Hermes Web UI:    http://192.168.0.225:9119
Slack bot:        nad9hermes

Storage state

SATA SSD is prepared for Frigate:

Disk: /dev/sda
Partition: /dev/sda1
Stable path: /dev/disk/by-id/ata-PNY_500GB_SATA_SSD_PNH05266000310302979-part1
Filesystem: XFS
Label: frigate_data
UUID: d70d9c1d-a67d-4540-88d8-e6e4fcbf5e9a
Mountpoint: /mnt/frigate
Mount options: noatime,inode64,logbufs=8,logbsize=262144

Frigate media directories:

/mnt/frigate/clips
/mnt/frigate/clips/thumbs
/mnt/frigate/recordings
/mnt/frigate/snapshots
/mnt/frigate/exports

Because CT 200 is unprivileged and uses a bind mount, ownership was fixed on the host:

chown -R 100000:100000 /mnt/frigate
chmod -R 775 /mnt/frigate

Current verified project steps

Step 01   Host validation                         verified
Step 02   Frigate storage                         verified
Step 03   Docker LXC foundation                   verified
Step 03B  Docker bootstrap in CT 200              verified
Step 03C  Hardware passthrough                    verified
Step 04   Frigate deployment                      verified
Step 04B  Frigate validation                      verified
Step 05   MQTT LXC deployment                     verified
Step 05B  MQTT validation                         verified
Step 06   Home Assistant OS VM                    verified
Step 06B  Home Assistant validation               verified
Step 07A  Home Assistant initial setup checklist  documentation
Step 07B  Frigate/MQTT/HA integration notes       documentation
Step 08   Hermes Agent LXC base                   verified
Step 08B  Hermes LXC validation                   verified
Step 08C  Hermes bootstrap                        verified
Step 08D  Hermes bootstrap validation             verified
Step 08E  Hermes provider/API config              verified
Step 08F  Hermes gateway service validation       verified
Step 09A  Hermes Slack mention integration        verified

Repository layout

Current repo:

~/proxmox-bootstrap

config/
  defaults.conf

docs/
  hermes-agent-kiss-setup-notes.md
  proxmox-command-cheat-sheet.md
  step07a-homeassistant-initial-setup-checklist.md
  step07b-frigate-mqtt-homeassistant-integration-notes.md
  step08e-hermes-provider-config.md

lib/
  cli.sh
  common.sh
  logging.sh
  runtime.sh
  validation.sh

logs/
  proxmox-bootstrap.log

scripts/
  proxmox-bootstrap.sh
  setup-frigate-disk.sh
  step01-host-validation.sh
  step02-storage.sh
  step03-docker-lxc.sh
  step03b-docker-bootstrap.sh
  step03c-hardware-passthrough.sh
  step04-frigate-deploy.sh
  step04b-frigate-validation.sh
  step05-mqtt-lxc.sh
  step05b-mqtt-validation.sh
  step06-homeassistant-vm.sh
  step06b-homeassistant-validation.sh
  step08-hermes-lxc.sh
  step08b-hermes-validation.sh
  step08c-hermes-bootstrap.sh
  step08d-hermes-validation.sh
  step08f-hermes-gateway-validation.sh
  step1-host-validation.sh
  test-framework.sh

README.md
.gitignore
.git/

Known old/duplicate file:

scripts/step1-host-validation.sh

This appears to be an old naming variant. Do not use unless intentionally cleaned up later.

Git state

Recent commit made:

Commit: 623024a
Message: Tune Hermes LXC resources and validation

That commit updated:

config/defaults.conf
scripts/step08-hermes-lxc.sh
scripts/step08b-hermes-validation.sh

Last known Git status:

On branch main
Your branch is ahead of 'origin/main' by 1 commit.

nothing to commit, working tree clean

Need to push:

git push

README and .gitignore were being created/improved next. If not committed yet, check:

git status

README.md status

Current README is good and should include:

- Project title and purpose
- Scope for nad9-1
- Current architecture
- Project principles
- Repository layout
- Quick start
- Main scripts
- Current verified milestones
- Hermes CT 220 baseline
- Common commands
- Safety notes
- Notes about not committing secrets/logs/runtime data

Important: README should use proper closed markdown code fences. A previous version was broken because the first architecture code block was not closed.

Recommended .gitignore

Create or keep .gitignore similar to:

# Logs
logs/
*.log

# Temporary files
*.tmp
*.temp
*.bak
*.orig
*.rej
*~

# Editor files
.vscode/
.idea/
*.swp
*.swo
Session.vim

# OS files
.DS_Store
Thumbs.db

# Secrets and environment files
.env
.env.*
*.key
*.pem
*.crt
*.p12
*.pfx
secrets/
credentials/
tokens/

# Proxmox / VM / container images
*.qcow2
*.raw
*.vmdk
*.img
*.iso
*.xz
*.zst

# Python/cache files
__pycache__/
*.pyc
.pytest_cache/

# Local runtime output
tmp/
cache/
downloads/

Do not commit logs/proxmox-bootstrap.log.

Step details

Step 01 - Host validation

Script:

scripts/step01-host-validation.sh

Validated:

Root access
Required commands
Virtualization support
KVM modules
Proxmox detection
Network/DNS
Storage mounts

Result:

Host validation passed.

Step 02 - Storage

Script:

scripts/step02-storage.sh

Validated Frigate disk and mount.

SATA SSD mounted at:

/mnt/frigate

XFS and fstab verified.

Step 03 - Docker/LXC foundation

Script:

scripts/step03-docker-lxc.sh

Created CT 200.

CT 200 config highlights:

ID: 200
Hostname: docker-core
Arch: amd64
Cores: 4
Memory: 4096
Swap: 512
Unprivileged: 1
Onboot: 1
Features: nesting=1,keyctl=1
Network: eth0 DHCP on vmbr0
Rootfs: local-lvm:vm-200-disk-0,size=16G
Mount: /mnt/frigate -> /mnt/frigate

Important fix:

CT_IP_CONFIG had to be "dhcp", not "ip=dhcp", because pct net0 already adds ip=.

Step 03B - Docker bootstrap

Script:

scripts/step03b-docker-bootstrap.sh

CT 200 got:

Docker installed
Docker Compose installed
Docker service active
Network and DNS working

CT 200 IP:

192.168.0.224

Docker versions observed:

Docker 29.6.1
Docker Compose v5.3.0

Step 03C - Hardware passthrough

Script:

scripts/step03c-hardware-passthrough.sh

Configured CT 200 passthrough.

Intel iGPU:

/dev/dri visible in CT 200
/dev/dri/renderD128 visible in CT 200

USB Coral TPU:

/dev/bus/usb visible in CT 200

LXC config lines added:

lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir

Step 04 - Frigate deployment

Script:

scripts/step04-frigate-deploy.sh

Frigate deployed in CT 200 with Docker Compose.

Image:

ghcr.io/blakeblackshear/frigate:stable

Frigate version seen in logs:

0.17.2-3d4dd3a

Frigate URL:

https://192.168.0.224:8971

Important behavior:

Frigate serves HTTPS on port 8971 with a self-signed/default certificate.
Validation must use curl -k.

Current minimal Frigate config:

mqtt:
  enabled: false

ffmpeg:
  hwaccel_args: preset-vaapi

detectors:
  coral:
    type: edgetpu
    device: usb

record:
  enabled: true
  retain:
    days: 7
    mode: motion

snapshots:
  enabled: true
  retain:
    default: 30

cameras: {}

Important fix:

Frigate initially had PermissionError on /media/frigate/clips.
Root cause was unprivileged CT bind mount ownership.
Fixed with host-side ownership 100000:100000 on /mnt/frigate.

Step 04B - Frigate validation

Script:

scripts/step04b-frigate-validation.sh

Read-only validation passed with:

0 warnings
0 errors

Checks include:

CT 200 running
Docker service active
Docker Compose available
Frigate compose/config files exist
/mnt/frigate media layout exists
media write access works
/dev/dri and renderD128 visible
/dev/bus/usb visible
Frigate container running and healthy
HTTPS endpoint 8971 returns HTTP 200
No permission denied
No Python traceback in checked logs
Frigate is attempting to use USB Coral TPU

Step 05 - MQTT LXC deployment

Script:

scripts/step05-mqtt-lxc.sh

Created CT 210 and installed native Mosquitto.

CT 210:

ID: 210
Hostname: mqtt-core
IP: 192.168.0.217
Mosquitto port: 1883

Issue found and fixed:

Mosquitto initially failed due duplicate persistence_location.
Debian default /etc/mosquitto/mosquitto.conf already has persistence_location.
Our /etc/mosquitto/conf.d/homelab.conf had duplicate settings.

Correct homelab Mosquitto config:

listener 1883 0.0.0.0
allow_anonymous true
log_dest syslog
log_dest stdout

Known harmless warning:

Locale warning: LANG=en_US.UTF-8 not generated.
This did not break Mosquitto.
Can be fixed later if desired.

Step 05B - MQTT validation

Script:

scripts/step05b-mqtt-validation.sh

Read-only validation passed with:

0 warnings
0 errors

Checks include:

CT 210 exists and running
Mosquitto service active
Mosquitto enabled
Port 1883 listening
homelab.conf exists
No duplicate persistence_location
Local MQTT pub/sub test succeeded
No obvious recent Mosquitto errors
Broker: 192.168.0.217:1883

Step 06 - Home Assistant OS VM

Script:

scripts/step06-homeassistant-vm.sh

Created VM 100 using Home Assistant OS image.

HAOS image used:

haos_ova-18.0.qcow2.xz
URL: https://github.com/home-assistant/operating-system/releases/download/18.0/haos_ova-18.0.qcow2.xz
Downloaded size: about 508 MB
Imported size: 32 GiB

VM 100 config:

agent: enabled=1
bios: ovmf
boot: order=scsi0
cores: 2
cpu: host
efidisk0: local-lvm:vm-100-disk-0,efitype=4m,pre-enrolled-keys=0,size=4M
machine: q35
memory: 4096
name: homeassistant
net0: virtio=BC:24:11:CF:06:BA,bridge=vmbr0
onboot: 1
ostype: l26
scsi0: local-lvm:vm-100-disk-1,discard=on,size=32G,ssd=1
scsihw: virtio-scsi-single
serial0: socket
tablet: 0
vga: serial0

Home Assistant IP:

192.168.0.218

Home Assistant URL:

http://192.168.0.218:8123

Verified in browser:

Home Assistant onboarding page shown.

Step 06B - Home Assistant validation

Script:

scripts/step06b-homeassistant-validation.sh

Read-only validation passed with:

0 warnings
0 errors

Checks include:

VM 100 exists
VM name is homeassistant
VM 100 running
OVMF/UEFI firmware
q35 machine type
Boots from scsi0
scsi0 disk attached
EFI disk attached
net0 attached to vmbr0
onboot enabled
guest agent enabled and responding
LAN IP detected: 192.168.0.218
HTTP endpoint returned HTTP 302
URL: http://192.168.0.218:8123

Home Assistant / Frigate / MQTT decisions

Current decisions:

Home Assistant stays as HAOS VM.
Mosquitto is external in CT 210, not a Home Assistant add-on.
Frigate is external in CT 200 with Docker Compose, not a Home Assistant add-on.
Frigate MQTT remains disabled until camera/config integration step.
Do not install duplicate Mosquitto or Frigate add-ons in Home Assistant.

Step 07 docs exist:

docs/step07a-homeassistant-initial-setup-checklist.md
docs/step07b-frigate-mqtt-homeassistant-integration-notes.md

Recommended next real project step:

Step 10 - Home Assistant, MQTT and Frigate integration

Suggested Step 10 scope:

1. Make sure Home Assistant can reach MQTT.
2. Configure MQTT integration in Home Assistant.
3. Enable MQTT in Frigate config.
4. Restart Frigate.
5. Verify Frigate publishes to MQTT.
6. Add Frigate integration in Home Assistant.
7. Only then add the first camera.

Key rule:

No new platform components until one camera is visible in Home Assistant through Frigate.

Hermes Agent current state

Hermes runs in CT 220.

CT 220:

CT ID:        220
Hostname:     hermes-agent
IP:           192.168.0.225
User:         hermes
Hermes home:  /home/hermes/.hermes
Base dir:     /opt/hermes
Service:      hermes-gateway.service
Web UI:       http://192.168.0.225:9119

Current Hermes architecture decision:

Keep Hermes simple.
Use system-wide Hermes gateway service.
Slack mentions work.
Web UI now works, but should be treated as optional.
Do not over-expand Hermes unless needed.

Stop doing for now:

No further Proxmox tuning without evidence.
No per-user service conversion.
No more Slack app rebuilds unless needed.
No doctor-warning cleanup unless it blocks real use.
No OpenAI OAuth/Codex setup right now.
No xAI/web-search API key cleanup right now.
No slash-command cleanup right now unless it becomes annoying.

Step 08 - Hermes Agent LXC base

Script:

scripts/step08-hermes-lxc.sh

Created CT 220:

ID: 220
Hostname: hermes-agent
IP: 192.168.0.225
User: hermes
Base dir: /opt/hermes
Python installed
DNS working
Base packages installed

Current CT 220 final resource baseline:

cores:     2
cpuunits:  2048
memory:    4096 MiB
swap:      0 MiB
features:  nesting=1,keyctl=1
cpulimit:  not explicitly configured

Important issue fixed:

Initial validation used:
pct exec 220 -- command -v python3

This failed because command is a shell builtin, not standalone binary.

Fixed to:
pct exec 220 -- bash -c 'command -v python3 >/dev/null 2>&1'

Current CT 220 state:

Running
Unprivileged
Onboot enabled
Features nesting=1,keyctl=1
Memory 4096 MiB
Swap 0 MiB
CPU units 2048
No explicit cpulimit

Hermes LXC resource tuning work completed

Problem:

Hermes in CT 220 felt much slower than the same Hermes setup on a Raspberry Pi Zero 2W.
Original CT resources were:
  cores: 2
  memory: 2048
  swap: 512

The Proxmox dashboard showed baseline memory usage and tiny swap usage.

Analysis:

LXC is not a full hypervisor VM.
The likely issue was not classic VM overhead.
Main suspects were memory headroom, swap behavior, Python/Hermes runtime overhead, network/API latency, and Web UI startup behavior.

Live fix applied:

pct shutdown 220 --timeout 30
pct set 220 -memory 4096 -swap 0 -cpuunits 2048
pct start 220

Verified live config:

cores: 2
cpuunits: 2048
features: nesting=1,keyctl=1
memory: 4096
swap: 0

Important note:

Do not set cpulimit.
There should be no explicit cpulimit line.
A previous attempt to hotplug cpulimit=0 failed with:
400 Parameter verification failed.
cpulimit: unable to hotplug cpulimit: closing file '/sys/fs/cgroup/lxc/220/cpu.max' failed - Invalid argument

Post-fix check:

Mem: 4.0 GiB
Used: about 342 MiB after restart
Free: about 3.4 GiB
Swap: 0B

Hermes direct CLI response test:

pct exec 220 -- su - hermes -c 'time hermes -z "Reply with exactly: OK"'

Result:

OK

real    0m4.544s
user    0m1.359s
sys     0m0.158s

Conclusion:

Hermes CLI/provider path is healthy.
LXC resources are no longer the obvious bottleneck.
If future latency appears, investigate provider/model/network/DNS/Slack/Web UI path before more Proxmox tuning.

Repo changes for Hermes resource tuning

The live CT fix was persisted into the repo.

Updated:

config/defaults.conf
scripts/step08-hermes-lxc.sh
scripts/step08b-hermes-validation.sh

config/defaults.conf now includes:

# Hermes Agent LXC defaults
HERMES_CT_ID="220"
HERMES_CT_HOSTNAME="hermes-agent"
HERMES_CT_MEMORY_MB="4096"
HERMES_CT_SWAP_MB="0"
HERMES_CT_CORES="2"
HERMES_CT_CPUUNITS="2048"
HERMES_CT_FEATURES="nesting=1,keyctl=1"

step08-hermes-lxc.sh now defaults to:

HERMES_CT_MEMORY_MB="${HERMES_CT_MEMORY_MB:-4096}"
HERMES_CT_SWAP_MB="${HERMES_CT_SWAP_MB:-0}"
HERMES_CT_CORES="${HERMES_CT_CORES:-2}"
HERMES_CT_CPUUNITS="${HERMES_CT_CPUUNITS:-2048}"

step08-hermes-lxc.sh now uses --cpuunits during pct create:

--memory "${HERMES_CT_MEMORY_MB}" \
--swap "${HERMES_CT_SWAP_MB}" \
--cores "${HERMES_CT_CORES}" \
--cpuunits "${HERMES_CT_CPUUNITS}" \

step08b-hermes-validation.sh now validates:

CPU cores
Memory
Swap
CPU units
No explicit cpulimit

It also now treats hermes-gateway.service as normal if it exists after Step 08C/08F.

Validation now passes cleanly:

Validation warnings: 0
Validation errors: 0
Hermes LXC validation completed successfully

Committed as:

623024a Tune Hermes LXC resources and validation

Step 08B - Hermes LXC validation

Script:

scripts/step08b-hermes-validation.sh

Current validation result:

0 warnings
0 errors

Checks include:

CT 220 exists and running
Hostname hermes-agent
LXC config hostname correct
onboot enabled
unprivileged enabled
nesting enabled
keyctl enabled
CPU cores 2
Memory 4096 MiB
Swap 0 MiB
CPU units 2048
No explicit cpulimit configured
IP detected: 192.168.0.225
default route exists
DNS works
Commands present: bash, curl, git, jq, python3, pip3, sudo, vim, wget
Python 3.13.5
pip 25.1.1
venv module works
hermes user exists
/home/hermes exists
/opt/hermes exists
ownership hermes:hermes
/home/hermes/.config exists
/home/hermes/.local/bin exists
/etc/sudoers.d/hermes-agent-base exists
sudoers syntax valid
hermes-gateway.service exists; expected after Step 08C/08F

Step 08C - Hermes bootstrap

Script:

scripts/step08c-hermes-bootstrap.sh

Purpose:

Install Hermes Agent CLI inside CT 220 as user hermes.
Create /usr/local/bin/hermes symlink.
Create /opt/hermes workspace/log dirs.
Create hermes-gateway.service.
Reload systemd.
Do not store API keys.

Official Hermes installer used:

curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

Installed files/state:

Hermes CLI: /home/hermes/.local/bin/hermes
Symlink: /usr/local/bin/hermes -> /home/hermes/.local/bin/hermes
Systemd service: /etc/systemd/system/hermes-gateway.service

Base packages now include:

ripgrep

Important fix:

Validation initially failed with “Hermes is not available in PATH”.
Reason: pct exec root PATH was /sbin:/bin:/usr/sbin:/usr/bin and did not include /usr/local/bin.
Fixed validation to use controlled PATH:
PATH=/usr/local/bin:/usr/bin:/bin command -v hermes
PATH=/usr/local/bin:/usr/bin:/bin hermes --help

Step 08D - Hermes bootstrap validation

Script:

scripts/step08d-hermes-validation.sh

This script was rewritten cleanly to match the project framework style:

Sources lib/common.sh
Sources config/defaults.conf
Uses framework logging/colors
Uses VALIDATION_ERRORS / VALIDATION_WARNINGS

Final validation result:

0 errors
0 warnings
Hermes bootstrap validation passed
ripgrep installed

Checks include:

CT 220 exists and running
Hermes CLI exists at /home/hermes/.local/bin/hermes
/usr/local/bin/hermes symlink works
Controlled PATH can find hermes
hermes --help works
/opt/hermes exists
/opt/hermes/workspaces exists
/opt/hermes/logs exists
/home/hermes/.hermes exists
hermes-gateway.service exists
sudoers helper exists and is valid
No API keys found in bootstrap script
ripgrep installed

Step 08E - Hermes provider/API config

Manual/documentation step.

Provider configured:

Provider: OpenRouter
Default model: nvidia/nemotron-3-ultra-550b-a55b:free
Config: /home/hermes/.hermes/config.yaml
Secrets: /home/hermes/.hermes/.env

API test:

hermes -z "Reply with exactly: Hermes provider test OK"

Result:

Hermes provider test OK

Doctor output confirmed:

✓ OpenRouter API

Warnings in hermes doctor are mostly optional and not blockers:

Nous Portal auth not logged in
OpenAI Codex auth not logged in
MiniMax OAuth not logged in
xAI OAuth not logged in
docker not found
agent-browser not installed
web search keys missing
x_search missing XAI_API_KEY
Skills Hub not initialized
No GITHUB_TOKEN

Decision:

Do not chase optional doctor warnings now.
OpenAI OAuth/Codex may be configured later.

Step 08F - Hermes gateway service

Gateway service is system-wide:

Service: hermes-gateway.service
Run user: hermes
State: enabled + active

Systemd unit after Hermes refresh:

Description: Hermes Agent Gateway - Messaging Platform Integration
ExecStart uses:
/home/hermes/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway run

Gateway status verified:

System gateway service is running.
Configured to run as: hermes.
System service starts at boot without requiring systemd linger.

Sudoers file:

/etc/sudoers.d/hermes-agent-base

Final intent:

Allow hermes user to manage only Hermes gateway service.
Do not grant broad root access.

Commands allowed or intended include:

sudo systemctl status hermes-gateway.service
sudo systemctl restart hermes-gateway.service
sudo systemctl start hermes-gateway.service
sudo systemctl stop hermes-gateway.service
sudo hermes gateway restart --system
sudo hermes gateway start --system
sudo hermes gateway stop --system
sudo hermes gateway status --system
sudo journalctl -u hermes-gateway.service --no-pager -n 80

Hermes Web UI

Hermes Web UI originally had problems but was later fixed by the user.

Current state:

Hermes Web UI works.
Port: 9119
Bind: 0.0.0.0:9119
URL: http://192.168.0.225:9119

Observed process:

/home/hermes/.hermes/hermes-agent/venv/bin/python3 /home/hermes/.hermes/hermes-agent/venv/bin/hermes dashboard --host 0.0.0.0 --port 9119 --no-open --skip-build

Port check:

pct exec 220 -- ss -ltnp | grep 9119 || true

Output:

LISTEN 0 2048 0.0.0.0:9119 0.0.0.0:* users:(("hermes",pid=354,fd=8))

Important note:

Web UI is working, but should still be treated as optional operational interface.
Do not expose port 9119 to the internet.
If permanent Web UI is desired, create a separate systemd service later.
Do not mix it into the gateway service.

Earlier finding:

Default bind was 127.0.0.1:9119.
LAN bind requires authentication.
Username/password auth was fixed by the user.

Step 09A - Hermes Slack integration

Slack integration is working.

Slack app/bot:

App/bot name: nad9hermes
Channel used for testing: nad9-proxmox
Interaction style: @mention

Verified Slack test:

Lasse:       hello @nad9hermes
nad9hermes: Hello! How can I help you today?

This confirms:

Slack app installed
Bot can receive mention
Hermes gateway receives Slack event
Hermes can respond in Slack thread

Important Slack setup notes:

Use a simple Slack app name/handle with no spaces or dash:
  nad9hermes

Do not use:
  NAD9 Hermes
  nad9-hermes

Slack display names can be prettier later, but the handle should stay simple.

Current Slack issue deferred:

Slack warned that Hermes installed generic slash commands, for example /undo, and this conflicts with an existing app named Moss.
This is a later cleanup problem.

Later cleanup:

Remove or disable generic slash commands:
  /undo
  /retry
  /new
  /start
  /stop
  /help
  /update
  /version
  /model

Keep:
  @nad9hermes mentions

Optional later:
  /nad9hermes

Decision:

For now, ignore slash-command conflict unless it becomes a practical problem.
Use @nad9hermes mentions only.

Current KISS Hermes decision

Current operating model:

Hermes CT 220
├── Hermes runs as user: hermes
├── Provider: OpenRouter
├── Gateway: system-wide systemd service
├── Slack: @nad9hermes mention works
└── Web UI: works, optional

Stop doing for now:

No more Hermes resource tuning unless there is new evidence.
No per-user service conversion.
No more Slack app rebuilds unless needed.
No doctor-warning cleanup unless it blocks real use.
No OpenAI OAuth/Codex setup right now.
No xAI/web-search API key cleanup right now.
No slash-command cleanup right now.
Do not expose Hermes Web UI directly to internet.

Daily Hermes commands:

pct enter 220
su - hermes

Check Hermes:

hermes doctor

Check gateway:

hermes gateway status

Restart gateway:

sudo hermes gateway restart --system

Use Slack:

@nad9hermes hello

Proxmox-native admin decision

Use the Proxmox host as the main admin entry point:

SSH to Proxmox host.
Then use pct enter / pct exec for LXC containers.
Use qm for VM management.
Do not install SSH into every LXC at this stage.

Examples:

pct list
qm list

pct enter 220
su - hermes
hermes gateway status

pct exec 210 -- systemctl status mosquitto
pct exec 200 -- bash -c 'cd /opt/frigate && docker compose ps'
qm status 100
qm agent 100 network-get-interfaces

Safety and architecture decisions

Home Assistant stays as HAOS VM.
Mosquitto is external in CT 210, not a Home Assistant add-on.
Frigate is external in CT 200 with Docker Compose, not a Home Assistant add-on.
Hermes is isolated in CT 220.
CT 200 is Frigate/Docker only.
CT 210 is MQTT only.
CT 220 is Hermes only.
API keys should never be added directly to repo scripts.
Do not expose services directly to the internet.
Future remote access should use VPN or secure tunnel.

Current stopping point

Current milestone complete:

Hermes provider works
Hermes gateway runs at boot
Hermes Web UI works
Slack mention integration works
Hermes CT resources tuned
Hermes setup script updated
Hermes validation script updated
Git commit created for Hermes resource tuning

Next immediate repo housekeeping:

1. Finish README.md and .gitignore.
2. Commit README.md and .gitignore.
3. Push commits to origin/main.

Commands likely needed:

git status
git add README.md .gitignore
git commit -m "Add project README and gitignore"
git push

Recommended next real project step after housekeeping:

Step 10 - Home Assistant + MQTT + Frigate integration

Suggested Step 10 plan:

1. Verify Home Assistant is reachable.
2. Verify MQTT broker is reachable from Home Assistant network.
3. Configure MQTT integration in Home Assistant.
4. Enable MQTT in Frigate config.
5. Restart Frigate.
6. Verify Frigate publishes to MQTT.
7. Add Frigate integration in Home Assistant.
8. Add first camera to Frigate.
9. Confirm camera/entities appear in Home Assistant.

Important rule:

No new platform components until one camera is visible in Home Assistant through Frigate.

Known later tasks

Create Step 09B Slack validation script
Clean up Slack slash command conflicts
Update step08c-hermes-bootstrap.sh with final sudoers rules if needed
Improve step08f validation log checking if needed
Configure OpenAI OAuth/Codex later if needed
Configure web search/xAI later if needed
Create permanent Hermes dashboard systemd service if user wants Web UI always running
Clean up old scripts/step1-host-validation.sh if no longer needed
Add gitignore if not already committed
Push local commits to origin/main