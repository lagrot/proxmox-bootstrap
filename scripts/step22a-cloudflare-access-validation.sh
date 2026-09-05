#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
ZONE_ID="${CLOUDFLARE_ZONE_ID:-cdc57b6899bf5275cad362cd8425b054}"
TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-}"
TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-nad9-remote-gateway}"
TOKEN="${CLOUDFLARE_API_TOKEN:-}"
HOSTNAME="${CLOUDFLARE_HA_HOSTNAME:-ha.ostmarken.se}"
OWNER_EMAIL="${CLOUDFLARE_HA_OWNER_EMAIL:-lasse.grotell@gmail.com}"
POLICY_NAME="${CLOUDFLARE_HA_ACCESS_POLICY_NAME:-Allow owner with OTP}"
TEAM_NAME="${CLOUDFLARE_ZERO_TRUST_TEAM_NAME:-ostmarken}"
ORGANIZATION_NAME="${CLOUDFLARE_ZERO_TRUST_ORGANIZATION_NAME:-Ostmarken}"

usage() {
  cat <<'EOF'
Usage: step22a-cloudflare-access-validation.sh [--access-only] | [--help]

Read-only validation of the Home Assistant Cloudflare Access application,
owner-only OTP policy, and, by default, unpublished DNS/tunnel state.
EOF
}

[[ "${1:-}" != "--help" ]] || { usage; exit 0; }
ACCESS_ONLY=0
if [[ $# -eq 1 && "$1" == "--access-only" ]]; then
  ACCESS_ONLY=1
elif [[ $# -ne 0 ]]; then
  die "Unknown argument: $1"
fi
[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in curl python3; do command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"; done
[[ "${ACCOUNT_ID}" =~ ^[0-9a-fA-F]{32}$ ]] || die "CLOUDFLARE_ACCOUNT_ID is invalid"
[[ "${ZONE_ID}" =~ ^[0-9a-fA-F]{32}$ ]] || die "CLOUDFLARE_ZONE_ID is invalid"
[[ -n "${TOKEN}" ]] || die "CLOUDFLARE_API_TOKEN is not set"

api_get() {
  curl -fsS -H "Authorization: Bearer ${TOKEN}" "https://api.cloudflare.com/client/v4/$1" \
    || die "Cloudflare API request failed: $1"
}

organization="$(api_get "accounts/${ACCOUNT_ID}/access/organizations")"
TEAM_DOMAIN="${TEAM_NAME}.cloudflareaccess.com" ORGANIZATION_NAME="${ORGANIZATION_NAME}" python3 -c '
import json,os,sys
r=json.load(sys.stdin).get("result") or {}
assert r.get("auth_domain")==os.environ["TEAM_DOMAIN"], "Unexpected Zero Trust team domain"
assert r.get("name")==os.environ["ORGANIZATION_NAME"], "Unexpected Zero Trust organization name"
' <<<"${organization}" || die "Zero Trust organization validation failed"

if [[ -z "${TUNNEL_ID}" ]]; then
  tunnels="$(api_get "accounts/${ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}")"
  TUNNEL_ID="$(TUNNEL_NAME="${TUNNEL_NAME}" python3 -c '
import json, os, sys
items = [x for x in json.load(sys.stdin).get("result", []) if x.get("name") == os.environ["TUNNEL_NAME"] and not x.get("deleted_at")]
if len(items) != 1:
    raise SystemExit("Expected exactly one matching tunnel")
print(items[0]["id"])
' <<<"${tunnels}")" || die "Could not discover tunnel ${TUNNEL_NAME}"
fi

idps="$(api_get "accounts/${ACCOUNT_ID}/access/identity_providers")"
otp_id="$(python3 -c '
import json, sys
items = [x for x in json.load(sys.stdin).get("result", []) if x.get("type") == "onetimepin"]
if len(items) != 1:
    raise SystemExit("Expected exactly one OTP identity provider")
print(items[0]["id"])
' <<<"${idps}")" || die "OTP identity provider validation failed"

apps="$(api_get "accounts/${ACCOUNT_ID}/access/apps?per_page=100")"
app_id="$(HOSTNAME="${HOSTNAME}" OTP_ID="${otp_id}" python3 -c '
import json, os, sys
items = [x for x in json.load(sys.stdin).get("result", []) if x.get("domain") == os.environ["HOSTNAME"]]
if len(items) != 1:
    raise SystemExit("Expected exactly one matching Access application")
app = items[0]
dest = app.get("destinations") or []
assert app.get("type") == "self_hosted", "Application is not self-hosted"
assert app.get("allowed_idps") == [os.environ["OTP_ID"]], "Application does not allow only OTP"
assert app.get("auto_redirect_to_identity") is True, "OTP auto-redirect is disabled"
assert app.get("allow_authenticate_via_warp") is False, "WARP authentication is unexpectedly enabled"
assert any(x.get("type") == "public" and x.get("uri") == os.environ["HOSTNAME"] for x in dest), "Public destination differs"
print(app["id"])
' <<<"${apps}")" || die "Access application validation failed"

policies="$(api_get "accounts/${ACCOUNT_ID}/access/apps/${app_id}/policies?per_page=100")"
POLICY_NAME="${POLICY_NAME}" OWNER_EMAIL="${OWNER_EMAIL}" OTP_ID="${otp_id}" python3 -c '
import json, os, sys
items = json.load(sys.stdin).get("result", [])
assert len(items) == 1, "Expected exactly one Access policy"
p = items[0]
assert p.get("name") == os.environ["POLICY_NAME"], "Unexpected policy name"
assert p.get("decision") == "allow", "Policy is not Allow"
assert p.get("include") == [{"email": {"email": os.environ["OWNER_EMAIL"]}}], "Policy email is not exact"
assert p.get("require") == [{"login_method": {"id": os.environ["OTP_ID"]}}], "Policy does not require OTP"
assert not p.get("exclude"), "Unexpected exclusions"
' <<<"${policies}" || die "Owner-only Access policy validation failed"

if [[ "${ACCESS_ONLY}" -eq 0 ]]; then
  dns="$(api_get "zones/${ZONE_ID}/dns_records?type=CNAME&name=${HOSTNAME}")"
  python3 -c 'import json,sys; assert len(json.load(sys.stdin).get("result", [])) == 0, "Hostname already has a DNS record"' \
    <<<"${dns}" || die "Expected ${HOSTNAME} to remain unpublished in DNS"

  config="$(api_get "accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations")"
  HOSTNAME="${HOSTNAME}" python3 -c '
import json, os, sys
result = json.load(sys.stdin).get("result") or {}
config = result.get("config") or {}
ingress = config.get("ingress") or []
assert not any(x.get("hostname") == os.environ["HOSTNAME"] for x in ingress), "Tunnel ingress already publishes hostname"
' <<<"${config}" || die "Expected ${HOSTNAME} to remain absent from tunnel ingress"
fi

log_info "Step 22A Cloudflare Access validation passed"
log_info "Zero Trust team domain: ${TEAM_NAME}.cloudflareaccess.com"
log_info "${HOSTNAME}: exact-email OTP policy for ${OWNER_EMAIL}"
if [[ "${ACCESS_ONLY}" -eq 0 ]]; then
  log_info "DNS and tunnel ingress: unpublished"
fi
