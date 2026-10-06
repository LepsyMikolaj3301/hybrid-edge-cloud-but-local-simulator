# CONTRACT (frozen once approved; changes require a plan update)

Single k3d cluster `edge-cloud`, namespaces `edge` and `cloud`. All images are pinned and built or imported locally.

## Components

| Component | NS | Image | Service DNS : port | NodePort -> host |
|---|---|---|---|---|
| mosquitto | edge | `eclipse-mosquitto:2.0.20` | `mosquitto.edge.svc:1883` | - |
| sensor-sim | edge | `edge-demo/sensor-sim:0.1.0` (local) | `sensor-sim.edge.svc:8080` (HTTP control, `/healthz`) | 30080 -> `localhost:8080` |
| edge-aggregator | edge | `edge-demo/edge-aggregator:0.1.0` (local) | `edge-aggregator.edge.svc:8000` (`/metrics`, `/healthz`) | 30800 -> `localhost:8000` |
| prometheus-edge (agent) | edge | `prom/prometheus:v3.5.0` | `prometheus-edge.edge.svc:9090` | - |
| edge-link (toxiproxy) | edge | `ghcr.io/shopify/toxiproxy:2.9.0` | proxy `edge-link.edge.svc:9091`, API `:8474` | 30474 -> `localhost:8474` |
| prometheus-cloud | cloud | `prom/prometheus:v3.5.0` | `prometheus-cloud.cloud.svc:9090` | 30090 -> `localhost:9090` |
| grafana | cloud | `grafana/grafana:11.5.2` | `grafana.cloud.svc:3000` | 30300 -> `localhost:3000` |

Data path: sim -MQTT-> aggregator <-scrape (2 s)- prometheus-edge -remote_write-> edge-link:9091 -> prometheus-cloud:9090/api/v1/write <- Grafana.

Prometheus v3 note: agent mode is the `--agent` flag. The v2 spelling `--enable-feature=agent` no longer exists.

Images use fixed tags and `imagePullPolicy: IfNotPresent` (never `:latest`).

## MQTT
- `sensors/vibration/raw`: QoS 0, JSON `{"ts": <unix float>, "value": <float>}`.
- `sensors/vibration/control`: JSON `{"cmd":"burst","duration_s":5,"amplitude":8.0}`.
- sensor-sim `POST /burst?duration_s=5&amplitude=8` on :8080 publishes that control message. The topic is the single trigger path.
- During a burst, each sample gets a spike of +/- amplitude with probability 0.3.

## sensor-sim env
`MQTT_HOST=mosquitto.edge.svc`, `MQTT_PORT=1883`, `SAMPLE_RATE_HZ=100`, `SIGNAL_FREQ_HZ=0.5`, `SIGNAL_AMPLITUDE=1.0`, `NOISE_STD=0.1`, `ANOMALY_RATE=0.001` (probability per sample), `ANOMALY_AMPLITUDE=6.0`, `HTTP_PORT=8080`.

## edge-aggregator env
`MQTT_HOST`, `MQTT_PORT`, `WINDOW_SECONDS=10`, `ANOMALY_THRESHOLD=3.0` (|value| > threshold is an anomaly), `ALERT_RMS_THRESHOLD=1.5`, `ALERT_WINDOW_SECONDS=1`, `METRICS_PORT=8000`.

## Metrics (all labelled `sensor="vibration"`)
- Gauges `edge_window_mean`, `edge_window_min`, `edge_window_max`, `edge_window_std`, `edge_window_rms`: updated when each tumbling window closes.
- `edge_anomaly_count` (gauge, anomalies in last window) and `edge_anomalies_total` (counter, incremented per sample).
- `edge_alert_active` (gauge 0/1): rolling `ALERT_WINDOW_SECONDS` RMS evaluated on every sample, raised when RMS > `ALERT_RMS_THRESHOLD`. The 10 s tumbling window would delay it, so it is not used. Logs `ALERT RAISED/CLEARED ts=...`.
- `edge_alert_last_change_timestamp_seconds` (gauge): addition to the brief, used by the latency script.
- `edge_raw_samples_total` (counter), `edge_aggregates_emitted_total` (counter, +1 per window close).
- Reduction ratio (Grafana): `rate(edge_raw_samples_total[1m]) / rate(edge_aggregates_emitted_total[1m])`, about 1000.
- Prometheus adds `job="edge-aggregator"`; the agent adds `external_labels: {site: "edge-1"}`.

## Prometheus settings
- Cloud: `--web.enable-remote-write-receiver --storage.tsdb.path=/prometheus`, `storage.tsdb.out_of_order_time_window: 1h`, data on a 1Gi PVC (k3d local-path) so scale-to-0 keeps history.
- Edge agent: `--agent --storage.agent.path=/data` (emptyDir, so the WAL survives cloud outages while the pod runs). `remote_write` to `http://edge-link.edge.svc:9091/api/v1/write` with explicit `queue_config` (`max_backoff: 5s`, `batch_send_deadline: 1s`). Scrape interval 2 s.

## Host ports
3000 (Grafana), 9090 (cloud Prometheus), 8000 (aggregator), 8080 (sim), 8474 (toxiproxy API). Traefik disabled.
