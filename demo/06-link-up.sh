#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"; repo_root
banner "DEMO 6: reconnect the cable (edge->cloud link UP)"
cat <<T
Toxiproxy proxy '$PROXY' is re-enabled. The edge agent replays its buffered WAL.
Grafana ($GRAFANA): the cloud series backfill the gap.
T
toxi_set_enabled true || fail "toxiproxy API call failed"
en=$(curl -fsS "$TOXI/proxies/$PROXY" | python3 -c 'import sys,json;print(json.load(sys.stdin)["enabled"])')
[ "$en" = "True" ] && pass "link is UP (enabled=$en)" || fail "proxy enabled=$en"
