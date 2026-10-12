# Seminar instruction: running the hybrid edge/cloud simulation

A step-by-step guide to start the simulation, log into Grafana, monitor it, run the demo scenarios and shut everything down. The README has the architecture and the reference details; this file is the order in which to do things.

## 0. What you are running

One local k3d (Kubernetes in Docker) cluster named `edge-cloud` with two namespaces:

- `edge`: sensor simulator (100 samples/s), MQTT broker, edge aggregator (10 s windows, local alert), edge Prometheus in agent mode, and Toxiproxy (the breakable "WAN link").
- `cloud`: cloud Prometheus (stores what arrives over the link) and Grafana.

Only aggregates cross the link. The raw samples stay at the edge.

## 1. Before you start

You need:

- Docker with the daemon running (on WSL2: Docker Desktop with WSL integration, or a working `docker` in WSL)
- `kubectl`, `make`, `python3`, `curl`
- Free host ports: **3000** (Grafana), **9090** (cloud Prometheus), **8000** (aggregator metrics), **8080** (sensor control), **8474** (Toxiproxy API)
- Internet access on the first run (images are pulled)

`k3d` is installed automatically by the setup script if it is missing.

## 2. Start the simulation

From the repository root:

```bash
./demo/00-setup.sh        # or: make up
```

This checks the tools and ports, creates the cluster, builds and imports the two local images, deploys everything and waits until the pods are ready. It takes about 10 minutes the first time.

Confirm it is healthy:

```bash
make status               # or ./demo/status.sh
kubectl --context k3d-edge-cloud get pods -A
```

All pods in the `edge` and `cloud` namespaces should be `Running`.

## 3. Log into Grafana

1. Open http://localhost:3000 in a browser.
2. You can already see the dashboards without logging in (anonymous access has the Viewer role).
3. To log in as an administrator, click **Sign in** (bottom left or top right) and use:
   - Username: `admin`
   - Password: `admin`
   - Grafana may offer to change the password. Click **Skip**; this is a local demo.
4. The home page is the dashboard **Edge -> Cloud Demo**. If you land somewhere else: menu, **Dashboards**, **Edge -> Cloud Demo**.
5. Set the time range to **Last 15 minutes** and auto-refresh to **5s** (top right).

On WSL2, if `localhost:3000` does not open from Windows, check that localhost forwarding is enabled, or use the WSL IP (`hostname -I`).

Grafana can be empty for about the first minute while data arrives.

## 4. What to look at on the dashboard

| Panel | What it tells you |
|---|---|
| Raw samples vs aggregates | About 100 samples/s are produced at the edge, but only about 0.1 aggregate/s crosses the link |
| Data reduction ratio | Raw rate divided by aggregate rate; about 1000 is expected |
| Window mean with min/max band | The summary of each 10 s window |
| Window RMS (alert threshold 1.5) | Vibration energy; the alert triggers above 1.5 |
| Alert state | 1 means the edge alert is active |
| Anomalies | Number of anomalous samples per window |
| Link health (edge agent remote_write) | Whether the edge agent is delivering to the cloud, retrying or failing |

## 5. Monitoring everything else

| What | Where / command |
|---|---|
| Grafana dashboards (cloud view) | http://localhost:3000 |
| Cloud Prometheus UI (run queries such as `edge_window_rms`) | http://localhost:9090 |
| Edge aggregator metrics (what the edge itself sees, works even when the link is down) | http://localhost:8000/metrics |
| Toxiproxy link state | `curl -s http://localhost:8474/proxies` |
| Pod status | `make status`, or `kubectl --context k3d-edge-cloud -n edge get pods` (also `-n cloud`) |
| Aggregator logs | `make logs` |
| Any pod logs | `kubectl --context k3d-edge-cloud -n edge logs deploy/sensor-sim --tail=50` |

Always pass `--context k3d-edge-cloud` to `kubectl` so you do not touch another cluster.

Useful queries in the Prometheus UI (http://localhost:9090):

```
edge_window_rms
edge_alert_active
rate(edge_raw_samples_total[1m])
rate(edge_aggregates_emitted_total[1m])
```

Edge Prometheus runs in agent mode and has no query UI. To see the edge side, use `curl http://localhost:8000/metrics`.

### Live watchers in the terminal

These run until Ctrl+C and print one line per tick. Open each in its own terminal, or run `make watch-all` to get all four in a 2x2 tmux session (detach with `Ctrl+b d`; close with `tmux kill-session -t edge-watch`).

| Script | What it shows |
|---|---|
| `watch/raw.sh` (`make watch-raw`) | The raw MQTT stream from the sensor: every 10th sample (`--every 1` shows all 100/s), anomalies (\|value\| > 3) in red, burst `CONTROL` messages in yellow |
| `watch/edge.sh` (`make watch-edge`) | What the edge aggregator sees, from :8000/metrics: raw counter climbing about 100/s, a marker each time a 10 s aggregate is emitted, window mean/min/max/RMS, and `ALERT` 0/1. It keeps going when the link is down |
| `watch/cloud.sh` (`make watch-cloud`) | What reached the cloud Prometheus: **age** of the newest edge sample (about 0-2 s when healthy, and it grows while data is not arriving), raw counter, raw rate, RMS, and alert. It prints `CLOUD PROMETHEUS DOWN` during the outage scenario |
| `watch/link.sh` (`make watch-link`) | The link: Toxiproxy UP/DOWN and toxics, plus the edge agent's remote_write queue: samples sent (and per second), pending, retried, failed, and **behind** (seconds of data buffered at the edge that the cloud does not have yet) |

Poll interval: `INTERVAL=1 watch/cloud.sh` (defaults: edge 1 s, cloud and link 2 s).

## 6. Run the demo scenarios

Run these from the repository root with the stack up and Grafana open next to the terminal. Each script prints PASS or FAIL at the end.

1. **Data reduction**: `./demo/01-data-reduction.sh`
   Watch "Raw samples vs aggregates" and "Data reduction ratio". Expect a ratio of about 1000.
   Terminal: `watch/raw.sh` + `watch/edge.sh` (100 raw samples/s in, one aggregate every 10 s out).
2. **Local alert**: `./demo/02-local-alert.sh`
   Injects an 8 s vibration burst. The edge raises the alert in about 0.2 s; the cloud sees it a second or two later. Watch "Alert state" and "Window RMS".
   Terminal: `watch/raw.sh` (CONTROL line, red spikes), `watch/edge.sh` (ALERT 1 almost at once) and `watch/cloud.sh` (ALERT 1 a moment later).
3. **Cloud outage and backfill**: `./demo/03-outage-backfill.sh`
   Shuts down the cloud Prometheus for 60 s, brings it back and checks for gaps. During the outage the cloud data looks missing; after recovery, **refresh the dashboard** and the gap is filled.
   Terminal: `watch/cloud.sh` (DOWN, then back) + `watch/link.sh` (pending/retried/behind grow, then drain).
4. **Latency (optional)**: `./demo/04-latency.sh`
   Adds 2 s latency to the link. The cloud alert lags; the edge alert does not. The script removes the latency when it exits.
   Terminal: `watch/link.sh` (toxic `lat:latency` listed) + `watch/edge.sh` / `watch/cloud.sh` (edge alert first, cloud lags).
5. **Manual link cut, for live narration**:
   - `./demo/05-link-down.sh`: the cloud series flatline, but http://localhost:8000/metrics keeps updating (the edge keeps working).
   - Wait 1 to 2 minutes while you explain.
   - `./demo/06-link-up.sh`: wait about 10 s, refresh Grafana, and the gap fills in.
   - Terminal: `watch/link.sh` (DOWN, pending and behind growing; after link-up both drop to 0 and sent/s spikes as the backlog is replayed), `watch/cloud.sh` (age climbs, then drops back to about 0 s), and `watch/edge.sh` (keeps updating the whole time).

You can also trigger a burst by hand:

```bash
curl -X POST "http://localhost:8080/burst?duration_s=5&amplitude=8"
```

Suggested seminar order: 1, 2, then 5/6 (or 3), then 4 if time allows.

## 7. Rules for a clean demo

- **Never restart or delete the `prometheus-edge` pod during or around an outage.** Its buffer is lost and the gap will not fill.
- Do not run two scenarios at once; wait for the PASS/FAIL line.
- If you stop in the middle of `05`, run `./demo/06-link-up.sh` before anything else.
- Timing numbers vary from run to run; treat the README numbers as examples.

## 8. Run the unit tests (optional)

```bash
./demo/run-tests.sh       # or: make test
```

Runs the aggregator tests inside a `python:3.11-slim` container. Expect 10 passed.

## 9. Shut down

```bash
./demo/99-teardown.sh     # or: make down
```

Deletes the k3d cluster and the two local images. To start again, run `./demo/00-setup.sh`.

## 10. Troubleshooting

| Symptom | Fix |
|---|---|
| Setup says a port is busy | Stop the program using it (3000, 9090, 8000, 8080 or 8474) and rerun |
| `ImagePullBackOff` | Run `make build`, then check `kubectl --context k3d-edge-cloud get pods -A`; for public images check the internet connection |
| Grafana is empty | Wait about a minute; check the time range is "Last 15 minutes" |
| Grafana still shows a gap after an outage | Refresh the dashboard |
| Cannot log in to Grafana | Use `admin` / `admin`, or just use anonymous viewing |
| Pods not ready | `make status`, then `kubectl --context k3d-edge-cloud -n edge describe pod <name>` |
| Everything is broken | `./demo/99-teardown.sh`, then `./demo/00-setup.sh` |

## 11. Quick cheat sheet

```bash
./demo/00-setup.sh                 # start (once)
open http://localhost:3000         # Grafana, admin/admin (or anonymous)
make status                        # health check
./demo/01-data-reduction.sh        # scenario 1
./demo/02-local-alert.sh           # scenario 2
./demo/05-link-down.sh             # cut the link
./demo/06-link-up.sh               # restore the link
./demo/99-teardown.sh              # stop and clean up
```
