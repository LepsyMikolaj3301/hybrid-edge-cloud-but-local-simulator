# Backfill spike findings (Prometheus v3.5.0 agent -> Toxiproxy 2.9.0 -> cloud Prometheus)

Raw data: `results/*.json`, `logs/`. Harness: `harness.py` (docker only, not k3d). One series, one run per variant, counts accurate to about one 2 s step at the boundaries.

Source of this write-up: the spike agent's report. Rows 3 and 4b I re-checked against the result files (0 raw missing scrapes in pre, outage and post). The other rows are as reported by the agent and not independently re-checked.

## Results

| # | Experiment | Outage | Raw missing scrapes | Notes |
|---|---|---|---|---|
| 1a | cloud `docker stop`, data kept | 62 s | 0 | agent lag grew to ~64 s, drained in under 5 s after the cloud was ready |
| 1b | cloud SIGKILL | 60 s | 0 | same as 1a |
| 1c | cloud recreated, named volume | 61 s | 0 | pre-outage history kept |
| 1d | cloud recreated, no volume | 61 s | 0 | all pre-outage history lost; the outage window was still backfilled |
| 2 | Toxiproxy `enabled=false` | 60 s | 0 | drained in about 5 s |
| 3 | cloud stopped 10 min, OOO window set | 601 s | 0 | no failed or dropped samples |
| 4a | no OOO window, 60 s | 61 s | 0 | identical to 1a |
| 4b | no OOO window, 10 min | 601 s | 0 | drained |
| 5a-c | agent `docker restart` mid-outage (WAL on tmpfs / volume / container layer) | ~31 s | 24 (one ~49 s gap) | unsent data lost in all three |
| 6 | 2000 ms upstream latency toxic | 60 s | 0 | lag 2-7 s while on, 0-2 s after removal |

The `query_range` check shows a baseline of about 4 empty steps at startup in every run.

## Conclusions
- Store-and-forward works for cloud and link outages, up to the 10 minutes tested. The agent retries with backoff capped at 5 s and catches up within seconds.
- The cloud out-of-order window is not what makes backfill work (4a, 4b). Keep `out_of_order_time_window: 1h` as a safety net only.
- The cloud PVC is needed to keep pre-outage history across pod recreation or scale-to-0 (1c vs 1d), not for backfill.
- An agent restart loses unsent data, whatever the WAL storage (5a-c). The demo must never restart `prometheus-edge` during an outage. This contradicts the contract's WAL-survival wording for agent restarts; it holds only for link and cloud outages.
- Check gaps with `count_over_time(metric[2s])` at step 2 s. A plain `query_range` hides gaps because of the 5-minute staleness lookback.
- Wait about 10 s after restoring before checking for gaps.

## Toxiproxy 2.9 calls that worked (API base `$T`)
```
curl -XPOST $T/proxies/<name> -d '{"enabled":false}'     # cut
curl -XPOST $T/proxies/<name> -d '{"enabled":true}'      # restore
curl -XPOST $T/proxies/<name>/toxics -d '{"name":"lat","type":"latency","stream":"upstream","toxicity":1.0,"attributes":{"latency":2000,"jitter":0}}'
curl -XDELETE $T/proxies/<name>/toxics/lat
curl -XPOST $T/reset
```
`stream` defaults to `downstream` if omitted. The spike used proxy name `edge-link`; the manifests use `prometheus-cloud`.

## Not tested / unverified
- Outages beyond 10 minutes, and WAL truncation behaviour. The agent believes the retention defaults are 5 m min and 4 h max, but did not measure them.
- Behaviour on k3d: emptyDir lifecycle, pod deletion, and scale-to-0 grace periods.
- Why a restart loses data. The agent's guess (the WAL watcher resumes at the end of the WAL) was not checked against the source.
- `docker restart` has a ~10 s graceful stop, which inflates the agent-down gap in 5a-c.
- Latency toxic tested only at 2000 ms under trivial load.
