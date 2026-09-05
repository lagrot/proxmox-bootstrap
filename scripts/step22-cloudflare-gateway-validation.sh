#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

CT_ID="${CLOUDFLARE_GATEWAY_CT_ID:-230}"
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-}"
TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-nad9-remote-gateway}"
TOKEN="${CLOUDFLARE_API_TOKEN:-}"

usage() {
  cat <<'EOF'
Usage: step22-cloudflare-gateway-validation.sh [--help]

Read-only validation of CT230 and its Cloudflare Tunnel connection.
Requires CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN in config/local.conf.
EOF
}

[[ "${1:-}" != "--help" ]] || { usage; exit 0; }
[[ $# -eq 0 ]] || die "Unknown argument: $1"
[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in curl pct python3; do command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"; done
[[ -n "${ACCOUNT_ID}" ]] || die "CLOUDFLARE_ACCOUNT_ID is not set"
[[ -n "${TOKEN}" ]] || die "CLOUDFLARE_API_TOKEN is not set"

if [[ -z "${TUNNEL_ID}" ]]; then
  tunnels="$(curl -fsS -G -H "Authorization: Bearer ${TOKEN}" \
    --data-urlencode "name=${TUNNEL_NAME}" \
    "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel")" \
    || die "Could not list Cloudflare tunnels"
  TUNNEL_ID="$(TUNNEL_NAME="${TUNNEL_NAME}" python3 -c '
import json, os, sys
items = [x for x in json.load(sys.stdin).get("result", []) if x.get("name") == os.environ["TUNNEL_NAME"] and not x.get("deleted_at")]
if len(items) != 1:
    raise SystemExit("Expected exactly one matching tunnel")
print(items[0]["id"])
' <<<"${tunnels}")" || die "Could not discover tunnel ${TUNNEL_NAME}"
fi

[[ "$(pct status "${CT_ID}" 2>/dev/null)" == "status: running" ]] || die "CT ${CT_ID} is not running"
pct exec "${CT_ID}" -- systemctl is-active --quiet cloudflared || die "cloudflared is not active in CT ${CT_ID}"
pct exec "${CT_ID}" -- cloudflared --version >/dev/null || die "cloudflared is unavailable in CT ${CT_ID}"

response="$(curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}")" \
  || die "Cloudflare tunnel API request failed"

grep -q '"success":true' <<<"${response}" || die "Cloudflare tunnel API returned failure"
grep -q '"status":"healthy"' <<<"${response}" || die "Cloudflare tunnel is not healthy"
grep -q '"remote_config":true' <<<"${response}" || die "Tunnel is not remotely managed"
grep -q '"connections":\[' <<<"${response}" || die "Tunnel has no connection list"

log_info "Step 22 Cloudflare gateway validation passed"
log_info "CT ${CT_ID}: running; cloudflared: active"
log_info "Tunnel ${TUNNEL_ID}: healthy and remotely managed"
