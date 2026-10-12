#!/usr/bin/env bash
# Live MQTT stream from the sensor: raw samples (throttled) and control messages.
# Usage: watch/raw.sh [--every N]   (print every Nth raw sample; default 10, 1 = all)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"; repo_root
EVERY=10
[ "${1:-}" = "--every" ] && EVERY=${2:?--every needs a number}
banner "WATCH raw: MQTT sensors/vibration/# (every ${EVERY}th sample, |value|>3.0 = anomaly)"
info "Ctrl+C to stop"
export EVERY C_R C_G C_Y C_BOLD C_0
PY='
import sys, os, json, time
every = int(os.environ["EVERY"]); R, G, Y, B, Z = (os.environ[k] for k in ("C_R", "C_G", "C_Y", "C_BOLD", "C_0"))
def main():
    n = 0; t_rate = time.time(); n_rate = 0; rate = 0.0
    for line in sys.stdin:
        topic, _, payload = line.strip().partition(" ")
        now = time.strftime("%H:%M:%S")
        if topic.endswith("/control"):
            print("%s %s%sCONTROL%s %s" % (now, B, Y, Z, payload), flush=True); continue
        n += 1; n_rate += 1
        if time.time() - t_rate >= 1:
            rate = n_rate / (time.time() - t_rate); t_rate = time.time(); n_rate = 0
        try:
            v = float(json.loads(payload)["value"])
        except Exception:
            print("%s ? %s" % (now, line.strip()), flush=True); continue
        anomaly = abs(v) > 3.0
        if anomaly or n % every == 0:
            bar = "#" * min(40, int(abs(v) * 5))
            col = R if anomaly else G
            print("%s #%-8d %s%+8.3f%s %5.0f msg/s  %s%s%s%s" % (now, n, col, v, Z, rate, col, bar, Z,
                  "  ANOMALY" if anomaly else ""), flush=True)
try:
    main()
except KeyboardInterrupt:
    pass
'
kc -n edge exec deploy/mosquitto -- mosquitto_sub -h localhost -v -t 'sensors/vibration/#' | python3 -u -c "$PY"
