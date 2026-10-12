#!/usr/bin/env bash
# The edge->cloud link: toxiproxy state + edge agent remote_write queue (pending/retried/failed).
# Usage: INTERVAL=2 watch/link.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"; repo_root
export INTERVAL=${INTERVAL:-2} CTX PROXY C_R C_G C_Y C_BOLD C_0
banner "WATCH link: toxiproxy '$PROXY' + prometheus-edge remote_write every ${INTERVAL}s"
info "Ctrl+C to stop. behind = seconds of data buffered at the edge, not yet sent to cloud"
exec python3 - <<'PY'
import os, time, json, subprocess, urllib.request
TOXI, PROXY, CTX, iv = os.environ["TOXI"], os.environ["PROXY"], os.environ["CTX"], float(os.environ["INTERVAL"])
R, G, Y, B, Z = (os.environ[k] for k in ("C_R", "C_G", "C_Y", "C_BOLD", "C_0"))
P = "prometheus_remote_storage_"

def link():
    p = json.loads(urllib.request.urlopen("%s/proxies/%s" % (TOXI, PROXY), timeout=2).read())
    return p["enabled"], ",".join("%s:%s" % (t["name"], t["type"]) for t in p.get("toxics", []))

def agent():
    txt = subprocess.run(["kubectl", "--context", CTX, "get", "--raw",
                          "/api/v1/namespaces/edge/services/prometheus-edge:9090/proxy/metrics"],
                         capture_output=True, text=True, timeout=5, check=True).stdout
    out = {}
    for line in txt.splitlines():
        if not line.startswith(P):
            continue
        name = line.split("{", 1)[0].split(" ", 1)[0]
        out[name] = out.get(name, 0.0) + float(line.rsplit(" ", 1)[1])
    return out

print("%-8s %-6s %-14s %10s %7s %8s %9s %7s %8s" % ("time", "link", "toxics", "sent", "sent/s", "pending", "retried", "failed", "behind"))
prev = None
try:
    while True:
        now = time.strftime("%H:%M:%S")
        try:
            en, tox = link()
            ls = (G + "UP    " + Z) if en else (B + R + "DOWN  " + Z)
        except Exception:
            ls, tox = R + "?     " + Z, "toxi unreachable"
        try:
            m = agent(); t = time.time()
            sent = m.get(P + "samples_total", 0)
            rate = (sent - prev[0]) / (t - prev[1]) if prev else 0.0
            pend = m.get(P + "samples_pending", 0)
            hi, hs = m.get(P + "highest_timestamp_in_seconds"), m.get(P + "queue_highest_sent_timestamp_seconds")
            behind = max(0.0, hi - hs) if hi and hs else None
            bcol = G if behind is not None and behind < 6 else R
            print("%-8s %s %-14s %10.0f %7.1f %s%8.0f%s %9.0f %7.0f %s%7ss%s" % (
                now, ls, tox or "-", sent, rate, R if pend > 1000 else "", pend, Z,
                m.get(P + "samples_retried_total", 0), m.get(P + "samples_failed_total", 0),
                bcol, "%.0f" % behind if behind is not None else "n/a", Z), flush=True)
            prev = (sent, t)
        except Exception as e:
            print("%-8s %s %-14s %sedge agent metrics unavailable%s (%s)" % (now, ls, tox or "-", R, Z, str(e).strip()[:80]), flush=True)
        time.sleep(iv)
except KeyboardInterrupt:
    pass
PY
