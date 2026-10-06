#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"; repo_root
banner "DEMO 3: cloud outage and backfill"
cat <<T
Cloud Prometheus is scaled to 0 for 60 s. The edge agent keeps scraping and
buffers in its WAL; on recovery it replays, and the cloud has NO gap.
Grafana ($GRAFANA): a flat/missing region during the outage that fills in afterwards.
T
restore() { kc -n cloud scale deploy prometheus-cloud --replicas=1 >/dev/null 2>&1 || true; }
trap restore EXIT
T0=$(python3 -c 'import time;print(int(time.time()))')
info "T0=$T0 (outage window [T0, T0+60])"
kc -n cloud scale deploy prometheus-cloud --replicas=0
countdown 60 "cloud down"
kc -n cloud scale deploy prometheus-cloud --replicas=1
kc -n cloud rollout status deploy/prometheus-cloud --timeout=180s
wait_http "$PROM_CLOUD/-/ready" 120 "prometheus-cloud" || fail "cloud Prometheus did not come back"
countdown 30 "waiting for agent to flush WAL"
START=$((T0-30)); END=$((T0+90))
python3 - "$T0" "$START" "$END" <<'PY' || RC=$?
import sys, json, urllib.request, urllib.parse, os
t0, start, end = map(int, sys.argv[1:4]); step = 2
q = 'max(count_over_time(edge_raw_samples_total{job="edge-aggregator"}[3s]))'
u = os.environ["PROM_CLOUD"] + "/api/v1/query_range?" + urllib.parse.urlencode(
    {"query": q, "start": start, "end": end, "step": step})
res = json.loads(urllib.request.urlopen(u, timeout=30).read())["data"]["result"]
have = {int(float(t)) for t, v in res[0]["values"]} if res else set()
steps = list(range(start, end + 1, step))
missing = [s for s in steps if s not in have]
def ranges(xs):
    out = []
    for s in xs:
        if out and s - out[-1][1] <= step: out[-1][1] = s
        else: out.append([s, s])
    return out
print("steps checked: %d, steps with a sample: %d, gaps: %d" % (len(steps), len(steps) - len(missing), len(missing)))
for a, b in ranges(missing):
    print("  missing %d..%d  (T0%+d .. T0%+d s)" % (a, b, a - t0, b - t0))
inwin = [s for s in missing if t0 <= s <= t0 + 60]
print("gaps inside outage window [T0, T0+60]: %d" % len(inwin))
sys.exit(0 if not inwin else 3)
PY
RC=${RC:-0}
echo
banner "Edge agent remote_write metrics (via API proxy to prometheus-edge:9090)"
# Agent mode has no query API, so read its /metrics text and sum the series.
AGENT_METRICS=$(kc get --raw "/api/v1/namespaces/edge/services/prometheus-edge:9090/proxy/metrics" 2>/dev/null || true)
for m in prometheus_remote_storage_samples_pending prometheus_remote_storage_samples_retried_total prometheus_remote_storage_samples_failed_total prometheus_remote_storage_samples_total; do
  v=$(printf '%s\n' "$AGENT_METRICS" | python3 -c '
import sys
name = sys.argv[1]; vals = []
for line in sys.stdin:
    if line.startswith(name + "{") or line.startswith(name + " "):
        vals.append(float(line.rsplit(" ", 1)[1]))
print("%g" % sum(vals) if vals else "")
' "$m" 2>/dev/null || true)
  printf '  %-58s %s\n' "$m" "${v:-unavailable}"
done
[ "$RC" -eq 0 ] && pass "no gaps in the outage window: edge buffered and backfilled" || fail "gaps found in outage window (see ranges above)"
