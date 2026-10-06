#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"; repo_root
banner "DEMO 1: edge data reduction"
cat <<T
The sensor emits ~100 raw samples/s; the edge aggregator ships one aggregate
per 10 s window. Only aggregates cross the link to the cloud.
Grafana ($GRAFANA): look at the "reduction ratio" / raw vs aggregate rate panels.
T
raw=$(prom_query 'sum(rate(edge_raw_samples_total[1m]))')
agg=$(prom_query 'sum(rate(edge_aggregates_emitted_total[1m]))')
ratio=$(prom_query 'sum(rate(edge_raw_samples_total[1m])) / sum(rate(edge_aggregates_emitted_total[1m]))')
echo "raw sample rate   : ${raw:-n/a} /s"
echo "aggregate rate    : ${agg:-n/a} /s"
echo "reduction ratio   : ${ratio:-n/a}  (expected ~1000)"
[ -n "$ratio" ] || fail "no data in cloud Prometheus yet (is the stack up and remote_write working?)"
if python3 -c "import sys; sys.exit(0 if float('$ratio')>100 else 1)"; then
  pass "reduction ratio $ratio > 100"
else
  fail "reduction ratio $ratio <= 100"
fi
