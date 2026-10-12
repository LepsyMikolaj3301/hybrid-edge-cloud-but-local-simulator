#!/usr/bin/env bash
# What the cloud sees: polls cloud Prometheus. "age" = how old the newest edge sample in the cloud is.
# Usage: INTERVAL=2 watch/cloud.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"; repo_root
export INTERVAL=${INTERVAL:-2} C_R C_G C_Y C_BOLD C_0
banner "WATCH cloud: $PROM_CLOUD every ${INTERVAL}s"
info "Ctrl+C to stop. age grows when data stops arriving (link down / outage)"
exec python3 - <<'PY'
import os, time, json, urllib.request, urllib.parse
PROM, iv = os.environ["PROM_CLOUD"], float(os.environ["INTERVAL"])
R, G, Y, B, Z = (os.environ[k] for k in ("C_R", "C_G", "C_Y", "C_BOLD", "C_0"))
Q = {
    "age": "time() - max(timestamp(edge_raw_samples_total))",
    "raw_total": "sum(edge_raw_samples_total)",
    "rate": "sum(rate(edge_raw_samples_total[1m]))",
    "rms": "max(edge_window_rms)",
    "mean": "max(edge_window_mean)",
    "alert": "max(edge_alert_active)",
}

def q(expr):
    u = PROM + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    r = json.loads(urllib.request.urlopen(u, timeout=3).read())["data"]["result"]
    return float(r[0]["value"][1]) if r else None

def f(v, fmt):
    return fmt % v if v is not None else "n/a"

print("%-8s %8s %10s %8s %8s %8s %s" % ("time", "age", "raw_total", "raw/s", "mean", "rms", "alert"))
try:
    while True:
        now = time.strftime("%H:%M:%S")
        try:
            v = {k: q(e) for k, e in Q.items()}
            age = v["age"]
            acol = G if age is not None and age < 6 else (Y if age is not None and age < 20 else R)
            alert = v["alert"] == 1
            print("%-8s %s%7ss%s %10s %8s %8s %8s %s" % (
                now, acol, f(age, "%.1f"), Z, f(v["raw_total"], "%.0f"), f(v["rate"], "%.1f"),
                f(v["mean"], "%+.3f"), f(v["rms"], "%.3f"),
                (B + R + "ALERT 1" + Z) if alert else (G + "ok 0" + Z)), flush=True)
        except Exception as e:
            print("%-8s %sCLOUD PROMETHEUS DOWN%s (%s)" % (now, B + R, Z, e), flush=True)
        time.sleep(iv)
except KeyboardInterrupt:
    pass
PY
