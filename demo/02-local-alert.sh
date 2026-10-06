#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"; repo_root
banner "DEMO 2: local (edge) alerting beats the cloud"
cat <<T
A vibration burst is injected. The edge aggregator raises edge_alert_active
within ~1 s from its rolling RMS, with no cloud involvement. The same alert
reaches the cloud only after scrape (2 s) + remote_write + query delay.
Grafana ($GRAFANA): watch the alert panel flip; compare edge vs cloud series.
T
out=$(alert_timing 8 30 | tee /dev/stderr | tail -1)
read -r _ edge cloud <<<"$out"
echo
echo "edge delay : ${edge} ms"
echo "cloud delay: ${cloud} ms"
[ "$edge" -ge 0 ] 2>/dev/null && [ "$edge" -lt 1000 ] || fail "edge alert not observed in <1s (edge=${edge} ms)"
[ "$cloud" -ge 0 ] || fail "edge ok (${edge} ms) but alert never observed in cloud"
pass "edge alert after ${edge} ms (<1000), cloud saw it after ${cloud} ms"
