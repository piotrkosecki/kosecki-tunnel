#!/usr/bin/env bash
# setup-cloudflare.sh — uses Cloudflare API to point *.<DOMAIN> at the VM's static IP.
#
#   CF_API_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxx  bash dns/setup-cloudflare.sh  34.91.x.x
#
# Scopes the token needs: Zone:DNS:Edit on the kosecki.dev zone.

set -euo pipefail

IP="${1:-}"
[[ -n "$IP" ]] || { echo "usage: CF_API_TOKEN=... bash $(basename "$0") <static-ip>"; exit 1; }
[[ -n "${CF_API_TOKEN:-}" ]] || { echo "CF_API_TOKEN env var is required"; exit 1; }
[[ -n "${CF_ZONE:-}" ]] || CF_ZONE="kosecki.dev"

api() {
    curl -fsS "https://api.cloudflare.com/client/v4$1" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        "${@:2}"
}

echo "── looking up zone id for $CF_ZONE ──"
ZONE_ID="$(api "/zones?name=${CF_ZONE}&status=active" \
            | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['result'][0]['id'])")"
echo "zone id: $ZONE_ID"

upsert() {
    local name="$1" type="A" content="$IP" proxied="false"
    # proxied=false => DNS-only (gray cloud). Required for Caddy HTTP-01 challenge
    # to hit this VM directly; Cloudflare proxy would intercept :80.
    existing="$(api "/zones/$ZONE_ID/dns_records?type=$type&name=$name")"
    record_id="$(echo "$existing" | python3 -c "import sys,json; r=json.load(sys.stdin); print((r['result'][0]['id'] if r['result'] else ''))")"
    body="$(python3 -c "import json,sys; print(json.dumps({'type':'$type','name':'$name','content':'$content','proxied':False,'ttl':60,'comment':'kosecki-tunnel VM'}))")"
    if [[ -n "$record_id" ]]; then
        echo "updating $name (id $record_id)"
        api "/zones/$ZONE_ID/dns_records/$record_id" -X PUT --data "$body" >/dev/null
    else
        echo "creating $name"
        api "/zones/$ZONE_ID/dns_records" -X POST --data "$body" >/dev/null
    fi
}

upsert "$CF_ZONE"        # apex
upsert "*.$CF_ZONE"      # wildcard
echo
echo "done. verify:"
echo "  dig +short $CF_ZONE"
echo "  dig +short q4.$CF_ZONE"
