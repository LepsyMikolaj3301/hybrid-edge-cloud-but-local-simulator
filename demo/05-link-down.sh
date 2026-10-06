#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"; repo_root
banner "DEMO 5: cut the cable (edge->cloud link DOWN)"
cat <<T
Toxiproxy proxy '$PROXY' is disabled: remote_write connections are refused.
The edge keeps working (alerts, local metrics); the cloud stops receiving data.
Grafana ($GRAFANA): cloud series flat-line; run demo/06-link-up.sh to reconnect.
T
toxi_set_enabled false || fail "toxiproxy API call failed"
en=$(curl -fsS "$TOXI/proxies/$PROXY" | python3 -c 'import sys,json;print(json.load(sys.stdin)["enabled"])')
[ "$en" = "False" ] && pass "link is DOWN (enabled=$en)" || fail "proxy still enabled=$en"
