#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"; repo_root
banner "DEMO 4: WAN latency (+2000 ms) on the edge->cloud link"
cat <<T
Toxiproxy adds 2000 ms latency to remote_write traffic. The edge alert time is
unchanged (local decision); the cloud sees it ~2 s later.
Grafana ($GRAFANA): cloud-side alert lags; edge alert is immediate.
T
cleanup() { curl -fsS -X DELETE "$TOXI/proxies/$PROXY/toxics/lat" >/dev/null 2>&1 || true; info "latency toxic removed"; }
trap cleanup EXIT
curl -fsS -X DELETE "$TOXI/proxies/$PROXY/toxics/lat" >/dev/null 2>&1 || true
# remote_write is a request (client->server = upstream); latency on upstream delays the data reaching the cloud.
curl -fsS -X POST -H 'Content-Type: application/json' \
  -d '{"name":"lat","type":"latency","stream":"upstream","toxicity":1.0,"attributes":{"latency":2000,"jitter":0}}' \
  "$TOXI/proxies/$PROXY/toxics" >/dev/null || fail "could not add toxic (is proxy '$PROXY' defined in toxiproxy?)"
info "toxic added; letting the queue settle for 10 s"
sleep 10
out=$(alert_timing 15 60 | tee /dev/stderr | tail -1)
read -r _ edge cloud <<<"$out"
echo
echo "edge delay : ${edge} ms"
echo "cloud delay: ${cloud} ms"
[ "$edge" -ge 0 ] 2>/dev/null && [ "$edge" -lt 1000 ] || fail "edge alert not <1s (edge=${edge} ms)"
[ "$cloud" -ge 0 ] || fail "cloud never observed alert"
[ "$cloud" -gt "$edge" ] || fail "cloud delay not larger than edge delay"
pass "edge ${edge} ms vs cloud ${cloud} ms with +2000 ms link latency"
