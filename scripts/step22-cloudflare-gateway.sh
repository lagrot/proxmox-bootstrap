#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

MODE=""
CT_ID="${CLOUDFLARE_GATEWAY_CT_ID:-230}"
CT_HOSTNAME="${CLOUDFLARE_GATEWAY_CT_HOSTNAME:-remote-gateway}"
TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-nad9-remote-gateway}"
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
TOKEN="${CLOUDFLARE_TUNNEL_API_TOKEN:-}"
TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-}"
TEMPLATE="${CLOUDFLARE_GATEWAY_TEMPLATE:-local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst}"

usage() {
  cat <<'EOF'
Usage: step22-cloudflare-gateway.sh --dry-run | --apply

Create or reuse the unprivileged Cloudflare Tunnel gateway CT and named tunnel.
Secrets are read from config/local.conf and are never printed.
EOF
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
case "$1" in
  --dry-run|--apply) MODE="$1" ;;
  --help) usage; exit 0 ;;
  *) die "Unknown argument: $1" ;;
esac

[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in curl openssl pct; do command -v "$cmd" >/dev/null || die "Missing command: $cmd"; done
[[ -n "${ACCOUNT_ID}" ]] || die "CLOUDFLARE_ACCOUNT_ID is not set"
[[ -n "${TOKEN}" ]] || die "CLOUDFLARE_TUNNEL_API_TOKEN is not set"

log_info "Step 22 Cloudflare gateway: ${MODE}"
log_info "CT ${CT_ID}, tunnel ${TUNNEL_NAME}"

if [[ "${MODE}" == "--dry-run" ]]; then
  pct status "${CT_ID}" >/dev/null 2>&1 && log_info "Would reuse existing CT ${CT_ID}" || log_info "Would create CT ${CT_ID} from ${TEMPLATE}"
  log_info "Would install cloudflared from Cloudflare's APT repository"
  log_info "Would reuse or create the named remote tunnel"
  log_info "Would install the connector token as a system service"
  exit 0
fi

pct status "${CT_ID}" >/dev/null 2>&1 || {
  [[ -f "/var/lib/vz/template/cache/${TEMPLATE#local:vztmpl/}" ]] || die "Missing template: ${TEMPLATE}"
  root_password="$(openssl rand -hex 24)"
  pct create "${CT_ID}" "${TEMPLATE}" \
    --hostname "${CT_HOSTNAME}" \
    --description 'Outbound-only Cloudflare Tunnel gateway' \
    --cores 1 --memory 512 --swap 512 --rootfs local-lvm:8 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp,type=veth \
    --nameserver 192.168.8.1 --unprivileged 1 --onboot 1 \
    --password "${root_password}"
}

[[ "$(pct status "${CT_ID}")" == "status: running" ]] || pct start "${CT_ID}"

pct exec "${CT_ID}" -- bash -euxo pipefail -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
  printf "%s\n" "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" > /etc/apt/sources.list.d/cloudflared.list
  apt-get update
  apt-get install -y cloudflared
'

if [[ -z "${TUNNEL_ID}" ]]; then
  tunnels="$(curl -fsS -G -H "Authorization: Bearer ${TOKEN}" \
    --data-urlencode "name=${TUNNEL_NAME}" \
    "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel")" \
    || die "Could not list Cloudflare tunnels"
  TUNNEL_ID="$(sed -n 's/.*"result":\[.*"id":"\([^"]*\)".*/\1/p' <<<"${tunnels}")"
  if [[ -z "${TUNNEL_ID}" ]]; then
    created="$(curl -fsS -X POST -H "Authorization: Bearer ${TOKEN}" \
      -H 'Content-Type: application/json' \
      --data "{\"name\":\"${TUNNEL_NAME}\",\"config_src\":\"cloudflare\"}" \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel")" \
      || die "Could not create Cloudflare tunnel"
    TUNNEL_ID="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' <<<"${created}")"
  fi
fi
[[ "${TUNNEL_ID}" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Could not determine a valid tunnel ID"

service_active=0
if pct exec "${CT_ID}" -- systemctl is-active --quiet cloudflared; then service_active=1; fi
if [[ "${service_active}" -eq 0 ]]; then
  curl -fsS -H "Authorization: Bearer ${TOKEN}" \
    "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token" \
  | sed -n 's/.*"result":"\([^"]*\)".*/\1/p' \
  | pct exec "${CT_ID}" -- sh -c 'IFS= read -r token; test -n "$token"; cloudflared service install "$token" >/tmp/cloudflared-install.log 2>&1; cat /tmp/cloudflared-install.log; rm -f /tmp/cloudflared-install.log'
  pct exec "${CT_ID}" -- systemctl enable --now cloudflared
fi

log_info "Cloudflare gateway setup completed for CT ${CT_ID} and tunnel ${TUNNEL_ID}"
