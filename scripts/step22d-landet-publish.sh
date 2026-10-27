#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
usage(){ echo 'Usage: step22d-landet-publish.sh --dry-run | --test-route | --apply | --validate | --rollback'; }
[[ $# == 1 ]] || { usage >&2; exit 2; }
case "$1" in --dry-run|--test-route|--apply|--validate|--rollback) mode="$1";; --help) usage; exit 0;; *) usage >&2; exit 2;; esac
for command in python3 pct flock dig; do command -v "$command" >/dev/null || { echo "Missing $command" >&2; exit 1; }; done
source "$ROOT/config/defaults.conf"
source "$ROOT/config/local.conf"
export CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN CLOUDFLARE_TUNNEL_ID
export CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-cdc57b6899bf5275cad362cd8425b054}"
# Serialize with the existing tunnel workflows; preview makes no lock/state file.
if [[ "$mode" == --apply || "$mode" == --rollback || "$mode" == --test-route ]]; then
 exec 9>/run/lock/proxmox-bootstrap-cloudflared.lock
 flock -n 9 || { echo 'Another tunnel operation is running' >&2; exit 1; }
fi
if [[ "$mode" != --rollback ]]; then
 bash "$ROOT/scripts/step22d-landet-deploy.sh" --validate
 ip="$(pct exec 240 -- ip -j -4 addr show dev eth0 | python3 -c 'import json,sys; ips=[x["local"] for a in json.load(sys.stdin) for x in a.get("addr_info",[]) if x.get("scope")=="global"]; assert ips==["192.168.8.124"], "Reserved viewer address differs"; print(ips[0])')"
 export LANDET_ORIGIN="http://${ip}:8080"
else
 export LANDET_ORIGIN="$(python3 -c 'import json; print(json.load(open("/var/lib/proxmox-bootstrap/landet/publication.json"))["route"]["service"])')"
fi
exec python3 "$ROOT/lib/landet_publish.py" "$mode"
