# Backfill findings (digest)

Short digest of `spike/backfill/FINDINGS.md`. That file has the full table and the raw data is in `spike/backfill/results/`.

**Question:** if the cloud or the link is down, does the edge Prometheus agent (`--agent`, v3.5.0) buffer its data and deliver it later, so the cloud has no gap?

**Method:** a Docker-only spike (not k3d): agent -> Toxiproxy 2.9.0 -> cloud Prometheus. One series, one run per variant. Counts are accurate to about one 2 s step.

## What was found

- **Store-and-forward works** for cloud outages and link outages. In every such run (cloud stopped, killed, recreated; link cut with Toxiproxy), 0 raw scrapes were missing afterwards. Outages of about 60 s and 10 min were tested. The agent retries with backoff capped at 5 s and catches up in seconds.
- **The out-of-order window is not what makes backfill work.** Runs with and without `out_of_order_time_window` behaved the same. The demo keeps `1h` as a safety net only.
- **The cloud PVC keeps pre-outage history.** If the cloud container or pod is recreated without persistent storage, the history from before the outage is lost. The outage window itself is still backfilled.
- **Restarting the agent during an outage loses the unsent data.** This happened with the WAL on tmpfs, on a volume and in the container layer. The demo must never restart `prometheus-edge`. This only matters if the agent itself restarts; link and cloud outages are safe.
- **+2000 ms latency** on the upstream direction made the agent lag 2-7 s while on, with no data loss.

## How to check for gaps

- Use `count_over_time(metric[2s])` at a 2 s step. A plain `query_range` hides gaps because of the 5 minute staleness lookback.
- Wait about 10 s after restoring before checking.

## Not tested

- Outages longer than 10 minutes, and WAL retention behaviour (believed to be 5 m minimum / 4 h maximum by default; not measured).
- Why an agent restart loses data (a guess only, not checked in the source).
- Latency other than 2000 ms, and latency under heavy load.
- The spike ran in Docker. Only the 60 s outage scenario (`demo/03-outage-backfill.sh`) was later run on k3d.
