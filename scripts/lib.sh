#!/usr/bin/env bash
# Shared helpers. Source this file; do not execute it.
export PATH="$HOME/.local/bin:$PATH"

CLUSTER=edge-cloud
CTX="k3d-${CLUSTER}"
K3D_VERSION=v5.8.3
SIM_IMAGE=edge-demo/sensor-sim:0.1.0
AGG_IMAGE=edge-demo/edge-aggregator:0.1.0
PROM_CLOUD=${PROM_CLOUD:-http://localhost:9090}
AGG=${AGG:-http://localhost:8000}
SIM=${SIM:-http://localhost:8080}
TOXI=${TOXI:-http://localhost:8474}
GRAFANA=${GRAFANA:-http://localhost:3000}
PROXY=prometheus-cloud
export PROM_CLOUD AGG SIM TOXI GRAFANA

if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
  C_R=; C_G=; C_Y=; C_B=; C_BOLD=; C_0=
fi

repo_root() {
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$d"
  REPO_ROOT="$d"
}

banner() { printf '\n%s== %s ==%s\n' "$C_BOLD$C_B" "$*" "$C_0"; }
info()   { printf '%s[info]%s %s\n' "$C_B" "$C_0" "$*"; }
warn()   { printf '%s[warn]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
pass()   { printf '\n%s%sPASS%s %s\n' "$C_BOLD" "$C_G" "$C_0" "$*"; }
fail()   { printf '\n%s%sFAIL%s %s\n' "$C_BOLD" "$C_R" "$C_0" "$*" >&2; exit 1; }
die()    { printf '%s[error]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

kc() { kubectl --context "$CTX" "$@"; }

cluster_exists() { k3d cluster list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$CLUSTER"; }

# prom_query EXPR -> prints value of first result of an instant query on cloud Prometheus (empty if none)
prom_query() {
  curl -fsS -G "$PROM_CLOUD/api/v1/query" --data-urlencode "query=$1" 2>/dev/null |
    python3 -c 'import sys,json
d=json.load(sys.stdin)
r=d.get("data",{}).get("result",[])
print(r[0]["value"][1] if r else "")' 2>/dev/null || true
}

# wait_http URL [timeout_s] [label]
wait_http() {
  local url=$1 to=${2:-120} label=${3:-$1} i=0
  while ! curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null; do
    i=$((i+1)); [ "$i" -ge "$to" ] && return 1; sleep 1
  done
  info "$label ready"
}

countdown() { # countdown SECONDS LABEL
  local n=$1
  while [ "$n" -gt 0 ]; do
    printf '\r%s  %s: %3ds remaining ' "$C_Y" "${2:-waiting}" "$n"; printf '%s' "$C_0"
    sleep 1; n=$((n-1))
  done
  printf '\r%-60s\r' ""
}

# toxi_set_enabled true|false
toxi_set_enabled() {
  curl -fsS -X POST -H 'Content-Type: application/json' -d "{\"enabled\":$1}" "$TOXI/proxies/$PROXY" >/dev/null
}

# alert_timing DURATION_S CLOUD_TIMEOUT_S -> prints "RESULT <edge_ms> <cloud_ms>" (-1 = not observed) as last line
alert_timing() {
  python3 - "${1:-8}" "${2:-30}" <<'PY'
import sys, time, urllib.request, urllib.parse, json, os
dur, cto = float(sys.argv[1]), float(sys.argv[2])
AGG, SIM, PROM = os.environ["AGG"], os.environ["SIM"], os.environ["PROM_CLOUD"]

def get(u, t=2):
    return urllib.request.urlopen(u, timeout=t).read().decode()

def alert():
    for line in get(AGG + "/metrics").splitlines():
        if line.startswith("edge_alert_active"):
            return float(line.rsplit(" ", 1)[1])
    return None

print("waiting for any previous alert to clear...", flush=True)
ok = 0; end = time.time() + 60
while time.time() < end and ok < 4:
    try:
        ok = ok + 1 if alert() == 0.0 else 0
    except Exception:
        ok = 0
    time.sleep(0.5)
if ok < 4:
    print("RESULT -1 -1 (alert never cleared)"); sys.exit(0)

t0 = time.time()
req = urllib.request.Request("%s/burst?duration_s=%s&amplitude=8" % (SIM, dur), data=b"", method="POST")
urllib.request.urlopen(req, timeout=5).read()
print("burst triggered at t0=%.3f" % t0, flush=True)

edge = -1.0
while time.time() - t0 < 15:
    try:
        if alert() == 1.0:
            edge = (time.time() - t0) * 1000; break
    except Exception:
        pass
    time.sleep(0.05)
print("edge alert observed after %.0f ms" % edge if edge >= 0 else "edge alert NOT observed", flush=True)

expr = ('max(edge_alert_active) * (max(edge_alert_last_change_timestamp_seconds) >= bool %.3f)' % t0)
cloud = -1.0
while time.time() - t0 < cto:
    try:
        u = PROM + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
        r = json.loads(get(u, 3))["data"]["result"]
        if r and r[0]["value"][1] == "1":
            cloud = (time.time() - t0) * 1000; break
    except Exception:
        pass
    time.sleep(0.5)
print("cloud alert observed after %.0f ms" % cloud if cloud >= 0 else "cloud alert NOT observed", flush=True)
print("RESULT %.0f %.0f" % (edge, cloud))
PY
}
