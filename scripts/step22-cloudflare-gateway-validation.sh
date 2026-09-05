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
TOKEN="${CLOUDFLARE_TUNNEL_API_TOKEN:-}"

usage() {
  cat <<'EOF'
Usage: step21-cloudflare-gateway-validation.sh [--help]

Read-only validation of CT230 and its Cloudflare Tunnel connection.
Requires CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_TUNNEL_API_TOKEN in config/local.conf.
EOF
}

[[ "${1:-}" != "--help" ]] || { usage; exit 0; }
[[ $# -eq 0 ]] || die "Unknown argument: $1"
[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in curl pct; do command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"; done
[[ -n "${ACCOUNT_ID}" ]] || die "CLOUDFLARE_ACCOUNT_ID is not set"
[[ -n "${TOKEN}" ]] || die "CLOUDFLARE_TUNNEL_API_TOKEN is not set"
[[ -n "${TUNNEL_ID}" ]] || die "CLOUDFLARE_TUNNEL_ID is not set"

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
