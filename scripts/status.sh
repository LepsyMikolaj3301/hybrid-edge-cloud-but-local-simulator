#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; repo_root
banner "Pods"
kc get pods -A -o wide 2>&1 | grep -E 'NAMESPACE|^(edge|cloud) ' || true
banner "Endpoints"
for u in "$GRAFANA/api/health" "$PROM_CLOUD/-/ready" "$AGG/healthz" "$SIM/healthz" "$TOXI/version"; do
  if curl -fsS -o /dev/null --max-time 2 "$u" 2>/dev/null; then printf '%sUP  %s %s\n' "$C_G" "$C_0" "$u"; else printf '%sDOWN%s %s\n' "$C_R" "$C_0" "$u"; fi
done
banner "Toxiproxy"
curl -fsS --max-time 2 "$TOXI/proxies" 2>/dev/null | python3 -c '
import sys,json
for n,p in json.load(sys.stdin).items():
    print(n, "enabled=%s" % p.get("enabled"), p.get("listen"), "->", p.get("upstream"), "toxics=%s" % [t["name"]+":"+t["type"]+"/"+t["stream"] for t in p.get("toxics",[])])' || echo "unreachable"
banner "Key metrics (cloud Prometheus)"
echo "edge_alert_active          = $(prom_query 'max(edge_alert_active)')"
echo "raw rate (1m)              = $(prom_query 'sum(rate(edge_raw_samples_total[1m]))')"
echo "aggregate rate (1m)        = $(prom_query 'sum(rate(edge_aggregates_emitted_total[1m]))')"
echo
echo "Grafana: $GRAFANA"
