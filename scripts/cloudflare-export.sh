#!/bin/sh
# Pull the Cloudflare edge configuration to disk.
#
# WHY THIS EXISTS. The tunnel, its network routes and the Zero Trust org are
# configuration that lives in exactly one place: Cloudflare's control plane. A
# cluster rebuild reproduces everything in kube/ from git and reproduces none
# of that. This script is the other half of the backup story -- run it after
# any change to the edge, commit the result, and a migration or an outage
# becomes a diff rather than an archaeology exercise.
#
# WHAT IT DELIBERATELY DOES NOT WRITE:
#
#   - the API token. It is piped from `op` straight into curl's --config on
#     stdin, so it never appears in argv (visible in `ps` to every process on
#     the machine), never in shell history, and never in a file here.
# The export DOES include connections[].origin_ip, the public address
# cloudflared is dialling out from. That was raised and the operator ruled it
# not a concern, so it is left in -- it is genuinely useful when working out
# which network a connector came up on.
#
# Usage:
#   sh scripts/cloudflare-export.sh [output-dir]      (default: backup/cloudflare)
#
# Requires: op (signed in), curl, python3.

set -eu

OUT="${1:-backup/cloudflare}"
ACCT=9c81bbbba3ad9c324c59631e93e0de8e
TUNNEL=6a7d35a4-3b3c-4700-8fba-636b76dff8e4
API=https://api.cloudflare.com/client/v4
ITEM='op://Personal/cloudflared-tunnel/credential'

mkdir -p "$OUT"

# One helper, one place the token is handled.
fetch() {
  op read --no-newline "$ITEM" \
    | sed 's|.*|header = "Authorization: Bearer &"|' \
    | curl -s --max-time 30 --config - "$1"
}

# Pretty-print and sort keys so the files diff cleanly between runs. An export
# that reorders itself every time is an export nobody reads the diff of.
write_json() {
  dest="$1"
  python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    sys.stderr.write('not JSON: %s\n' % e); sys.exit(1)
json.dump(d.get('result', d), open('$dest', 'w'), indent=2, sort_keys=True)
open('$dest', 'a').write('\n')
"
}

echo "exporting to $OUT"

fetch "$API/accounts/$ACCT/cfd_tunnel/$TUNNEL"          | write_json "$OUT/tunnel.json"
echo "  tunnel.json"

fetch "$API/accounts/$ACCT/cfd_tunnel/$TUNNEL/configurations" | write_json "$OUT/tunnel-config.json"
echo "  tunnel-config.json"

fetch "$API/accounts/$ACCT/teamnet/routes"              | write_json "$OUT/network-routes.json"
echo "  network-routes.json"

fetch "$API/accounts/$ACCT/access/organizations"        | write_json "$OUT/zero-trust-org.json"
echo "  zero-trust-org.json"

# These need Zero Trust scopes the tunnel token does not carry. Attempted
# anyway and recorded as unavailable rather than silently skipped: a backup
# that quietly omits a section is worse than one that says what it could not
# reach.
for pair in "devices/policy:device-policy" "gateway/rules:gateway-rules"; do
  path="${pair%%:*}"; name="${pair##*:}"
  if fetch "$API/accounts/$ACCT/$path" | write_json "$OUT/$name.json" 2>/dev/null; then
    echo "  $name.json"
  else
    printf '{\n  "unavailable": "the tunnel-scoped token cannot read %s; export this from the dashboard or mint a token with Zero Trust scope"\n}\n' "$path" > "$OUT/$name.json"
    echo "  $name.json (unavailable -- token lacks scope)"
  fi
done

echo "done. Commit these; they are configuration, not secrets."
