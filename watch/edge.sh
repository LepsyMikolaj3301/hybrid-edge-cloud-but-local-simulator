#!/usr/bin/env bash
# What the edge itself sees: polls the aggregator /metrics (works even when the link is down).
# Usage: INTERVAL=1 watch/edge.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"; repo_root
export INTERVAL=${INTERVAL:-1} C_R C_G C_Y C_BOLD C_0
banner "WATCH edge: $AGG/metrics every ${INTERVAL}s"
info "Ctrl+C to stop"
exec python3 - <<'PY'
import os, time, urllib.request
AGG, iv = os.environ["AGG"], float(os.environ["INTERVAL"])
R, G, Y, B, Z = (os.environ[k] for k in ("C_R", "C_G", "C_Y", "C_BOLD", "C_0"))

def metrics():
    out = {}
    for line in urllib.request.urlopen(AGG + "/metrics", timeout=2).read().decode().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        name = line.split("{", 1)[0].split(" ", 1)[0]
        out[name] = out.get(name, 0.0) + float(line.rsplit(" ", 1)[1])
    return out

print("%-8s %10s %7s %6s %8s %8s %8s %7s %5s %s" % ("time", "raw_total", "raw/s", "aggs", "mean", "min", "max", "rms", "anom", "alert"))
prev = None; prev_t = None; i = 0
try:
    while True:
        now = time.strftime("%H:%M:%S")
        try:
            m = metrics(); t = time.time()
            raw, agg = m.get("edge_raw_samples_total", 0), m.get("edge_aggregates_emitted_total", 0)
            rate = (raw - prev[0]) / (t - prev_t) if prev else 0.0
            new_agg = prev is not None and agg != prev[1]
            alert = m.get("edge_alert_active", 0) == 1
            rms = m.get("edge_window_rms", 0)
            print("%-8s %10.0f %7.1f %s%6.0f%s %+8.3f %+8.3f %+8.3f %s%7.3f%s %5.0f %s%s" % (
                now, raw, rate, (B + Y) if new_agg else "", agg, Z,
                m.get("edge_window_mean", 0), m.get("edge_window_min", 0), m.get("edge_window_max", 0),
                R if rms > 1.5 else "", rms, Z, m.get("edge_anomaly_count", 0),
                (B + R + "ALERT 1" + Z) if alert else (G + "ok 0" + Z),
                ("   <- new 10 s aggregate" if new_agg else "")), flush=True)
            prev, prev_t = (raw, agg), t
        except Exception as e:
            print("%-8s %sEDGE AGGREGATOR UNREACHABLE%s (%s)" % (now, R, Z, e), flush=True); prev = None
        time.sleep(iv)
except KeyboardInterrupt:
    pass
PY
