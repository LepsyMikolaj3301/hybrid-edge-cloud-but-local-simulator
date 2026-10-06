#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; repo_root
banner "Waiting for pods"
for ns in cloud edge; do
  i=0
  until [ -n "$(kc -n "$ns" get pods -o name 2>/dev/null)" ]; do
    i=$((i+1)); [ $i -ge 60 ] && die "no pods appeared in namespace $ns"; sleep 2
  done
  kc -n "$ns" wait --for=condition=Ready pod --all --timeout=300s
done
banner "Waiting for host endpoints"
wait_http "$GRAFANA/api/health" 120 "grafana"          || die "grafana not reachable"
wait_http "$PROM_CLOUD/-/ready" 120 "prometheus-cloud" || die "prometheus-cloud not reachable"
wait_http "$AGG/healthz"        120 "edge-aggregator"  || die "edge-aggregator not reachable"
wait_http "$SIM/healthz"        120 "sensor-sim"       || die "sensor-sim not reachable"
wait_http "$TOXI/version"       120 "toxiproxy API"    || die "toxiproxy API not reachable"
info "all components ready"
