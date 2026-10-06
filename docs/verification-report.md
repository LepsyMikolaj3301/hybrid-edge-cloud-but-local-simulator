# Independent verification report (WP7)

Date: 2026-10-06. Verifier did not edit code, manifests, scripts or README. All evidence below is from commands run during this session (raw logs were in /tmp/v during the run). Unrelated adhd-* containers were never touched (still running at the end).

## Summary table

| # | Step | Result |
|---|------|--------|
| 1 | Clean state (`./demo/99-teardown.sh`) | PASS |
| 2 | From scratch `./demo/00-setup.sh` | PASS (1m56.5s, then 1m52.9s on a second from-scratch run) |
| 3 | Live data in cloud Prometheus | PASS, with one transient mismatch (78/s at ~1 min after start, see below) |
| 4 | Dashboard / Grafana API, every panel expression | PASS (13 of 13 expressions non-empty) |
| 5 | Scenarios 01, 02, 03, 04, 05, 06 | PASS (all exit 0); scenario 3 independently confirmed, and re-run once more on a fresh stack |
| 6 | Tests (`run-tests.sh`, `make test`) | PASS (10 passed, 10 passed) |
| 7 | README check | PASS with minor findings (no broken command, port, URL or file reference found) |
| 8 | Idempotence (`make up` twice, `make down`) | PASS |
| 9 | Stack left UP via `./demo/00-setup.sh` | PASS |

## Step 1: clean state
`./demo/99-teardown.sh` exit 0, "Successfully deleted cluster edge-cloud!", "PASS cluster removed".
`k3d cluster list` printed only the header (`NAME SERVERS AGENTS LOADBALANCER`). `docker images | grep edge-demo` returned nothing. Only the three adhd-* containers remained in `docker ps`.

## Step 2: from scratch
`time ./demo/00-setup.sh`: exit 0, `real 1m56.476s`. Ends with "all components ready" and "PASS stack is up".
Caveat: Docker image layers for the public images may have been cached on this machine; a truly cold internet pull was not measured.
`kubectl --context k3d-edge-cloud get pods -n edge`: edge-aggregator, edge-link, mosquitto, prometheus-edge, sensor-sim all `1/1 Running`, 0 restarts. `-n cloud`: grafana, prometheus-cloud `1/1 Running`, 0 restarts.

## Step 3: live data (first query ~1 min after readiness)
```
rate(edge_raw_samples_total[1m])                    78.13
rate(edge_aggregates_emitted_total[1m])             0.0711
ratio                                               1100
edge_window_rms                                     0.743
edge_alert_active                                   0
```
Direct measurement from localhost:8000/metrics over 20 s: `edge_raw_samples_total` 9372 -> 11372, i.e. exactly 100.0 samples/s.
Mismatch: 78.1/s in the cloud vs 100.0/s direct. This is the young-series `rate()` extrapolation artifact (the README already documents a similar one). A minute later the same query returned 97.57, and demo 01 later showed a cloud-side 99.85/s (status.sh showed 99.85). Not a data-loss defect, but it is visible right after startup.

## Step 4: Grafana
- `/api/health`: `{"database":"ok","version":"11.5.2"}`
- `/api/datasources`: one Prometheus datasource, uid `prometheus-cloud`, url `http://prometheus-cloud.cloud.svc:9090`, isDefault true. Querying through Grafana's proxy (`/api/datasources/proxy/uid/prometheus-cloud/api/v1/query?query=up`) returned data. Anonymous access works; `admin:admin` returns 200 on `/api/user`.
- `/api/dashboards/uid/edge-cloud`: HTTP 200, title "Edge -> Cloud Demo". All panel and target datasource refs are `prometheus-cloud`.
- Each target executed against localhost:9090 (`$__rate_interval` replaced by 1m). Result: every one returned 1 series (non-empty).

| Panel | Expression | Rows |
|---|---|---|
| 1 Raw vs aggregates | `rate(edge_raw_samples_total[30s])` | 1 |
| 1 | `rate(edge_aggregates_emitted_total[30s])` | 1 |
| 2 Reduction ratio | `rate(edge_raw_samples_total[1m]) / rate(edge_aggregates_emitted_total[1m])` | 1 |
| 3 Mean/min/max | `edge_window_max`, `edge_window_min`, `edge_window_mean` | 1 each |
| 4 Window RMS | `edge_window_rms` | 1 |
| 5 Alert state | `edge_alert_active` | 1 |
| 6 Anomalies | `edge_anomaly_count`, `increase(edge_anomalies_total[1m])` | 1 each |
| 7 Link health | `prometheus_remote_storage_samples_pending{job="prometheus-edge"}`, `rate(..._failed_total{...}[1m])`, `rate(..._retried_total{...}[1m])` | 1 each |

Empty panels: none. Limit: rendering in a browser was not inspected (no browser used); "non-empty query result" is what was verified. Panel 7 failed/retried series are present but are zero when the link is healthy.

## Step 5: scenarios (all run on the stack from step 2)
- 01 data reduction: exit 0. raw 99.87/s, aggregate 0.1033/s, ratio 966.7. "PASS reduction ratio 966.67 > 100".
- 02 local alert: exit 0. edge 109 ms, cloud 1617 ms. PASS.
- 03 outage/backfill: exit 0. My own timestamp: script start 1791322537, T0=1791322537, end 1791322630. Independent query `count_over_time(edge_raw_samples_total{job="edge-aggregator"}[3s])` (no `max()` wrapper) with step 2 over [T0-30, T0+90]: 61 steps, 61 present, missing = [], every step had count 1 (single series). Counter deltas per 2 s across the outage window were all exactly 200 (no missing raw samples). Script verdict "steps checked: 61 ... gaps: 0 ... PASS" agrees. Agent counters: retried_total 9500, failed_total 0, pending 42.
  Reproduction: re-ran on the fresh stack from step 8/9: exit 0, gaps inside outage window 0, retried 9500, failed 0, PASS. (2 runs total; only 60 s outage tested.)
- 04 latency: exit 0. edge 162 ms, cloud 4689 ms. "latency toxic removed". `curl localhost:8474/proxies/prometheus-cloud/toxics` -> `[]`.
- 05 link down: exit 0, "PASS link is DOWN (enabled=False)". Proxy JSON `"enabled":false`. 20 s later the cloud's newest `edge_raw_samples_total` sample was 21.3 s old (stalled) while the aggregator kept counting (27105 on :8000).
- 06 link up: exit 0, "PASS link is UP (enabled=True)". After it: cloud sample lag 2.4 s; proxy `"enabled":true,"toxics":[]`; `/toxics` -> `[]`. Last 2.5 minutes (spanning the 05/06 cut), 76 of 76 two-second steps present (backfilled, no gap).

## Step 6: tests
`./demo/run-tests.sh`: exit 0, "10 passed in 0.20s", "PASS tests passed". `make test`: exit 0, "10 passed in 0.17s". Cosmetic noise: pip root warning and pip upgrade notice on every run (the test script installs packages inside the container each time, so it needs network).

## Step 7: README check
Followed the Quickstart literally (`./demo/00-setup.sh`), then ran every other command named: `demo/status.sh`, `make status`, `make logs`, `make build` (exists in Makefile), `./demo/99-teardown.sh`, `./demo/run-tests.sh`, `curl -X POST 'localhost:8080/burst?duration_s=5&amplitude=8'` (returned `{"published": {...burst...}}`). Verified existence of CONTRACT.md, docs/backfill-findings.md, ports 3000/9090/8000/8080/8474 (all answered), dashboard title, all 11 contract metric names on :8000/metrics, env values in k8s configmaps (WINDOW_SECONDS 10, ANOMALY_THRESHOLD 3.0, ALERT_RMS_THRESHOLD 1.5, ALERT_WINDOW_SECONDS 1), and pinned images (prom/prometheus v3.5.0, grafana 11.5.2, toxiproxy 2.9.0, mosquitto 2.0.20 all in manifests). Observed "10 passed" matches.
Nothing named that does not exist. Findings:
- README says "about 10 minutes"; measured 1m53s-1m56s, but with a possibly warm Docker image cache. Cold-pull time not demonstrated.
- README's "k3d is installed automatically ... if missing" was not tested (k3d already installed in ~/.local/bin).
- README numbers (e.g. "934 and 1134", "0 gaps", "163 ms") are labelled as examples; my runs were in the same ballpark (967, 109/162 ms, 0 gaps).
- Troubleshooting "WSL2" advice not exercised.
- demo/status.sh is the README script and `make status` works; both fine.

## Step 8: idempotence
`make up` on the running stack: exit 0, 19.0 s, "cluster edge-cloud already exists, skipping create", all manifests `unchanged`, "all components ready", no errors, no non-Running pods.
`make down`: exit 0. `k3d cluster list` empty, no edge-demo images, `ss -ltn` shows nothing listening on 3000/9090/8000/8080/8474, no k3d docker network or volume left, adhd-* containers untouched.

## Step 9
`./demo/00-setup.sh` exit 0, `real 1m52.937s`, "PASS stack is up". All 5 edge pods and 2 cloud pods `1/1 Running`, Grafana health ok, proxy enabled, no toxics. Stack is UP at end of the verification.

## Defects (none blocking)
| # | Severity | Description | Reproduction |
|---|---|---|---|
| D1 | Low | Cloud-side `rate(edge_raw_samples_total[1m])` reads ~78/s (and reduction ratio/panel values off) in the first minute or two after startup, vs true 100/s | `./demo/00-setup.sh`, wait for data, query immediately; README mentions this class of artifact |
| D2 | Low (doc) | "10 minute" claim not shown for a cold Docker cache; measured only warm | n/a |
| D3 | Cosmetic | demo logs contain carriage-return countdown spam; run-tests prints pip root warnings and needs network each run | run 03, run-tests |
| D4 | Info | Scenario 3 verified only for 60 s outage, two runs; scenario 3's script gap check wraps `max()`, but my unwrapped check gave the same result | n/a |

## Definition of done
Demonstrated: make up works from clean (twice from scratch, 1m53s-1m56s; also idempotent on a running stack); every dashboard panel expression returns live data via Prometheus and the Grafana datasource proxy (verified at the query level, not by looking at rendered panels); the 3 mandatory scenarios (01, 02, 03) pass, with scenario 3 independently re-checked and run twice (plus optional 04, 05, 06 pass); unit tests pass (10/10, both entry points).
Not demonstrated: panels visually rendered in a browser; README-to-running in under 10 minutes for a genuine newcomer with a cold image cache and fresh machine (only a scripted, warm-cache run of about 2 minutes, and the README read-through); automatic k3d installation; reproducibility beyond two scenario-3 runs and outage lengths other than 60 s.
