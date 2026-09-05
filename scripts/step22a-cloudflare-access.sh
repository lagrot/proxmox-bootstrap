#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/config/defaults.conf"
[[ -f "${PROJECT_ROOT}/config/local.conf" ]] && source "${PROJECT_ROOT}/config/local.conf"

MODE=""
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
TOKEN="${CLOUDFLARE_API_TOKEN:-}"
HOSTNAME="${CLOUDFLARE_HA_HOSTNAME:-ha.ostmarken.se}"
OWNER_EMAIL="${CLOUDFLARE_HA_OWNER_EMAIL:-lasse.grotell@gmail.com}"
IDP_NAME="${CLOUDFLARE_OTP_IDP_NAME:-One-time PIN login}"
APP_NAME="${CLOUDFLARE_HA_ACCESS_APP_NAME:-Home Assistant}"
POLICY_NAME="${CLOUDFLARE_HA_ACCESS_POLICY_NAME:-Allow owner with OTP}"
TEAM_NAME="${CLOUDFLARE_ZERO_TRUST_TEAM_NAME:-ostmarken}"
ORGANIZATION_NAME="${CLOUDFLARE_ZERO_TRUST_ORGANIZATION_NAME:-Ostmarken}"
API_BASE="https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}"

usage() {
  cat <<'EOF'
Usage: step22a-cloudflare-access.sh --dry-run | --apply

Create or reuse a Cloudflare One-time PIN identity provider, then create a
self-hosted Access application for Home Assistant with an exact-email policy.
This script does not create DNS records or tunnel ingress routes.
EOF
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
case "$1" in
  --dry-run|--apply) MODE="$1" ;;
  --help) usage; exit 0 ;;
  *) die "Unknown argument: $1" ;;
esac

[[ "${EUID}" -eq 0 ]] || die "Run as root"
for cmd in curl python3; do command -v "${cmd}" >/dev/null || die "Missing command: ${cmd}"; done
[[ "${ACCOUNT_ID}" =~ ^[0-9a-fA-F]{32}$ ]] || die "CLOUDFLARE_ACCOUNT_ID is not a valid account ID"
[[ -n "${TOKEN}" ]] || die "CLOUDFLARE_API_TOKEN is not set"
[[ "${HOSTNAME}" =~ ^[A-Za-z0-9.-]+$ ]] || die "CLOUDFLARE_HA_HOSTNAME is invalid"
[[ "${OWNER_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "CLOUDFLARE_HA_OWNER_EMAIL is invalid"
[[ "${TEAM_NAME}" =~ ^[a-z0-9-]+$ ]] || die "CLOUDFLARE_ZERO_TRUST_TEAM_NAME is invalid"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

api_request() {
  local method="$1" endpoint="$2" body="${3:-}" output="${tmp_dir}/response.json" status
  if [[ -n "${body}" ]]; then
    status="$(curl -sS -o "${output}" -w '%{http_code}' -X "${method}" \
      -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
      --data "${body}" "${API_BASE}${endpoint}")" || die "Cloudflare API request failed: ${method} ${endpoint}"
  else
    status="$(curl -sS -o "${output}" -w '%{http_code}' -X "${method}" \
      -H "Authorization: Bearer ${TOKEN}" "${API_BASE}${endpoint}")" || die "Cloudflare API request failed: ${method} ${endpoint}"
  fi
  if [[ ! "${status}" =~ ^2 ]]; then
    python3 - "${output}" "${status}" <<'PY' >&2
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    messages = [str(x.get("message", x)) for x in data.get("errors", [])]
except Exception:
    messages = []
print(f"Cloudflare API returned HTTP {sys.argv[2]}" + (": " + "; ".join(messages) if messages else ""))
PY
    exit 1
  fi
  python3 - "${output}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if not data.get("success"):
    raise SystemExit("Cloudflare API reported failure: " + "; ".join(str(x.get("message", x)) for x in data.get("errors", [])))
PY
  cat "${output}"
}

json_matches() {
  local kind="$1" value="$2"
  python3 -c '
import json, sys
kind, value = sys.argv[1:]
items = json.load(sys.stdin).get("result", [])
if kind == "idp":
    matches = [x for x in items if x.get("type") == "onetimepin"]
elif kind == "app":
    matches = [x for x in items if x.get("domain") == value]
elif kind == "policy":
    matches = [x for x in items if x.get("name") == value]
else:
    raise SystemExit("unknown match kind")
print(len(matches))
if len(matches) == 1:
    print(matches[0].get("id", ""))
' "${kind}" "${value}"
}

log_info "Step 22A Cloudflare Access: ${MODE}"
log_info "Application ${HOSTNAME}; allowed identity ${OWNER_EMAIL}"
api_request GET "/tokens/verify" >/dev/null

organization="$(api_request GET '/access/organizations')"
organization_state="$(TEAM_DOMAIN="${TEAM_NAME}.cloudflareaccess.com" ORGANIZATION_NAME="${ORGANIZATION_NAME}" python3 -c '
import json, os, sys
r=json.load(sys.stdin).get("result") or {}
print("correct" if r.get("auth_domain")==os.environ["TEAM_DOMAIN"] and r.get("name")==os.environ["ORGANIZATION_NAME"] else "change")
' <<<"${organization}")"

idps="$(api_request GET '/access/identity_providers')"
mapfile -t idp_match < <(json_matches idp "" <<<"${idps}")
[[ "${idp_match[0]}" -le 1 ]] || die "Multiple one-time PIN identity providers exist; refusing an ambiguous change"
otp_id="${idp_match[1]:-}"

apps="$(api_request GET '/access/apps?per_page=100')"
mapfile -t app_match < <(json_matches app "${HOSTNAME}" <<<"${apps}")
[[ "${app_match[0]}" -le 1 ]] || die "Multiple Access applications match ${HOSTNAME}"
app_id="${app_match[1]:-}"

if [[ "${MODE}" == "--dry-run" ]]; then
  [[ "${organization_state}" == "correct" ]] && log_info "Would reuse Zero Trust team domain ${TEAM_NAME}.cloudflareaccess.com" || log_info "Would change the Zero Trust team domain to ${TEAM_NAME}.cloudflareaccess.com"
  [[ -n "${otp_id}" ]] && log_info "Would reuse OTP identity provider ${otp_id}" || log_info "Would create OTP identity provider ${IDP_NAME}"
  [[ -n "${app_id}" ]] && log_info "Would reuse and verify Access application ${app_id}" || log_info "Would create Access application for ${HOSTNAME}"
  log_info "Would enforce one allow policy: exact email ${OWNER_EMAIL}, requiring OTP"
  log_info "Would not create DNS or tunnel ingress"
  exit 0
fi

if [[ "${organization_state}" != "correct" ]]; then
  organization_body="$(TEAM_DOMAIN="${TEAM_NAME}.cloudflareaccess.com" ORGANIZATION_NAME="${ORGANIZATION_NAME}" python3 -c 'import json,os; print(json.dumps({"auth_domain":os.environ["TEAM_DOMAIN"],"name":os.environ["ORGANIZATION_NAME"]}))')"
  api_request PUT '/access/organizations' "${organization_body}" >/dev/null
  log_info "Changed Zero Trust team domain to ${TEAM_NAME}.cloudflareaccess.com"
else
  log_info "Reusing Zero Trust team domain ${TEAM_NAME}.cloudflareaccess.com"
fi

if [[ -z "${otp_id}" ]]; then
  idp_body="$(IDP_NAME="${IDP_NAME}" python3 - <<'PY'
import json, os
print(json.dumps({"name": os.environ["IDP_NAME"], "type": "onetimepin", "config": {}}))
PY
)"
  created_idp="$(api_request POST '/access/identity_providers' "${idp_body}")"
  otp_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])' <<<"${created_idp}")"
  log_info "Created OTP identity provider ${otp_id}"
else
  log_info "Reusing OTP identity provider ${otp_id}"
fi

if [[ -z "${app_id}" ]]; then
  app_body="$(APP_NAME="${APP_NAME}" HOSTNAME="${HOSTNAME}" OTP_ID="${otp_id}" python3 - <<'PY'
import json, os
print(json.dumps({
    "name": os.environ["APP_NAME"],
    "type": "self_hosted",
    "domain": os.environ["HOSTNAME"],
    "destinations": [{"type": "public", "uri": os.environ["HOSTNAME"]}],
    "session_duration": "24h",
    "allowed_idps": [os.environ["OTP_ID"]],
    "auto_redirect_to_identity": True,
    "app_launcher_visible": False,
    "allow_authenticate_via_warp": False,
}))
PY
)"
  created_app="$(api_request POST '/access/apps' "${app_body}")"
  app_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])' <<<"${created_app}")"
  log_info "Created Access application ${app_id}"
else
  existing_ok="$(OTP_ID="${otp_id}" HOSTNAME="${HOSTNAME}" python3 -c '
import json, os, sys
items = json.load(sys.stdin).get("result", [])
apps = [x for x in items if x.get("domain") == os.environ["HOSTNAME"]]
app = apps[0] if len(apps) == 1 else {}
dest = app.get("destinations") or []
ok = (app.get("type") == "self_hosted"
      and app.get("allowed_idps") == [os.environ["OTP_ID"]]
      and app.get("auto_redirect_to_identity") is True
      and any(x.get("type") == "public" and x.get("uri") == os.environ["HOSTNAME"] for x in dest))
print("yes" if ok else "no")
' <<<"${apps}")"
  [[ "${existing_ok}" == "yes" ]] || die "Existing ${HOSTNAME} Access application differs from the safe desired configuration"
  log_info "Reusing verified Access application ${app_id}"
fi

policies="$(api_request GET "/access/apps/${app_id}/policies?per_page=100")"
policy_total="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("result", [])))' <<<"${policies}")"
mapfile -t policy_match < <(json_matches policy "${POLICY_NAME}" <<<"${policies}")
[[ "${policy_match[0]}" -le 1 ]] || die "Multiple policies named ${POLICY_NAME} exist"
[[ "${policy_total}" -le 1 ]] || die "Unexpected additional policies exist on ${HOSTNAME}; refusing to broaden access"

policy_body="$(POLICY_NAME="${POLICY_NAME}" OWNER_EMAIL="${OWNER_EMAIL}" OTP_ID="${otp_id}" python3 - <<'PY'
import json, os
print(json.dumps({
    "name": os.environ["POLICY_NAME"],
    "decision": "allow",
    "precedence": 1,
    "include": [{"email": {"email": os.environ["OWNER_EMAIL"]}}],
    "require": [{"login_method": {"id": os.environ["OTP_ID"]}}],
    "exclude": [],
}))
PY
)"

if [[ "${policy_match[0]}" -eq 0 ]]; then
  api_request POST "/access/apps/${app_id}/policies" "${policy_body}" >/dev/null
  log_info "Created owner-only OTP Access policy"
else
  policy_id="${policy_match[1]}"
  api_request PUT "/access/apps/${app_id}/policies/${policy_id}" "${policy_body}" >/dev/null
  log_info "Reconciled owner-only OTP Access policy ${policy_id}"
fi

log_info "Cloudflare Access setup completed; DNS and tunnel routes were not changed"
