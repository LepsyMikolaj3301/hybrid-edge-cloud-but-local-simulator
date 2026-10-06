#!/usr/bin/env python3
"""Backfill spike harness (stdlib only). Usage: harness.py <exp-name> [key=value ...]
keys: outage=60 mode=stop|kill|recreate|recreate_novol|toxi|latency ooo=1|0
      agent_store=tmpfs|volume|layer  agent_restart=0|1 warm=90 settle=100 idx=N
Each experiment gets a private docker network + containers prefixed bf-<name>-.
"""
import json, os, subprocess, sys, time, urllib.request, urllib.parse, shutil, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROM = "prom/prometheus:v3.5.0"
TOX = "ghcr.io/shopify/toxiproxy:2.9.0"

def sh(cmd, check=True):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and r.returncode:
        raise RuntimeError(f"{cmd}\n{r.stdout}\n{r.stderr}")
    return r.stdout.strip()

def http(method, url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        t = r.read().decode()
        return json.loads(t) if t.startswith(("{", "[")) else t

def wait_http(url, n=60):
    for _ in range(n):
        try:
            urllib.request.urlopen(url, timeout=2).read(); return
        except Exception: time.sleep(1)
    raise RuntimeError("timeout " + url)

def metrics(url):
    out = {}
    for line in urllib.request.urlopen(url, timeout=5).read().decode().splitlines():
        if line.startswith("#") or not line.strip(): continue
        k, _, v = line.rpartition(" ")
        if k.startswith("prometheus_remote_storage_") or k.startswith("prometheus_agent_") or k.startswith("prometheus_tsdb_out_of") or k.startswith("prometheus_tsdb_head_out_of") or k.startswith("prometheus_tsdb_head_samples_appended"):
            try: out[k] = float(v)
            except ValueError: pass
    return out

def main():
    name = sys.argv[1]
    o = dict(a.split("=") for a in sys.argv[2:])
    outage = int(o.get("outage", 60)); mode = o.get("mode", "stop")
    ooo = o.get("ooo", "1") == "1"; astore = o.get("agent_store", "tmpfs")
    arestart = o.get("agent_restart", "0") == "1"
    warm = int(o.get("warm", 90)); settle = int(o.get("settle", 100)); idx = int(o.get("idx", 0))
    P = f"bf-{name}-"; net = P + "net"
    cport, aport, tport = 19000+idx*10, 19001+idx*10, 19002+idx*10
    cur = f"http://127.0.0.1:{cport}"; aur = f"http://127.0.0.1:{aport}"; tur = f"http://127.0.0.1:{tport}"
    os.makedirs(HERE+"/.run",exist_ok=True); tmp = tempfile.mkdtemp(prefix=name+"-",dir=HERE+"/.run"); os.chmod(tmp, 0o755)
    shutil.copy(os.path.join(HERE, "cloud-ooo.yml" if ooo else "cloud-noooo.yml"), tmp + "/cloud.yml")
    a = open(HERE + "/agent.yml").read().replace("SRC", P+"src").replace("TOX", P+"tox")
    open(tmp + "/agent.yml", "w").write(a)
    shutil.copy(HERE + "/source.py", tmp + "/source.py")
    for f in os.listdir(tmp): os.chmod(os.path.join(tmp, f), 0o644)
    ev = []   # event log (name, unix ts)
    def mark(n): ev.append((n, time.time())); print(f"[{name}] {n} @ {time.strftime('%H:%M:%S')}", flush=True)
    created_vols = [P+"cloud", P+"agent"]

    timeline = []
    def lagof(m):
        hts = [v for k, v in m.items() if k.startswith("prometheus_remote_storage_highest_timestamp_in_seconds")]
        sent = [v for k, v in m.items() if k.startswith("prometheus_remote_storage_queue_highest_sent_timestamp_seconds")]
        pend = [v for k, v in m.items() if k.startswith("prometheus_remote_storage_samples_pending")]
        return (round(hts[0] - sent[0], 1) if hts and sent else None, pend[0] if pend else None)
    def wait(secs):
        end = time.time() + secs
        while time.time() < end:
            try:
                lag, pend = lagof(metrics(aur + "/metrics")); timeline.append((round(time.time() - ev[0][1]), lag, pend))
            except Exception: timeline.append((round(time.time() - ev[0][1]), "agent-down", None))
            time.sleep(min(5, max(0, end - time.time())))
    def run_cloud(vol=True):
        v = f"-v {P}cloud:/prometheus" if vol else ""
        sh(f"docker run -d --name {P}cloud --network {net} -p 127.0.0.1:{cport}:9090 {v} -v {tmp}:/cfg:ro "
           f"{PROM} --config.file=/cfg/cloud.yml --storage.tsdb.path=/prometheus --web.enable-remote-write-receiver")
    def run_agent():
        st = {"tmpfs": "--tmpfs /data:rw,mode=1777", "volume": f"-v {P}agent:/data", "layer": ""}[astore]
        sh(f"docker run -d --name {P}agent --user 0 --network {net} -p 127.0.0.1:{aport}:9090 {st} -v {tmp}:/cfg:ro "
           f"{PROM} --agent --config.file=/cfg/agent.yml --storage.agent.path=/data")
    def cleanup(rm_tmp=True):
        sh(f"docker rm -f -v {P}cloud {P}agent {P}tox {P}src", check=False)
        sh(f"docker network rm {net}", check=False)
        sh(f"docker volume rm -f {' '.join(created_vols)}", check=False)
        sh(f"docker volume prune -f >/dev/null", check=False) if False else None
        if rm_tmp: shutil.rmtree(tmp, ignore_errors=True)
    cleanup(False)
    try:
        sh(f"docker network create {net}")
        sh(f"docker run -d --name {P}src --network {net} -v {tmp}:/cfg:ro python:3.11-slim python /cfg/source.py")
        sh(f"docker run -d --name {P}tox --network {net} -p 127.0.0.1:{tport}:8474 {TOX}")
        run_cloud(); wait_http(cur + "/-/ready"); wait_http(tur + "/version")
        # Toxiproxy: create proxy
        http("POST", tur + "/proxies", {"name": "edge-link", "listen": "0.0.0.0:9091", "upstream": f"{P}cloud:9090", "enabled": True})
        run_agent(); wait_http(aur + "/-/ready")
        mark("start"); t_start = time.time()
        wait(warm)
        a0 = metrics(aur + "/metrics")
        mark("outage_begin")
        if mode == "stop": sh(f"docker stop {P}cloud")
        elif mode == "kill": sh(f"docker kill {P}cloud")
        elif mode in ("recreate", "recreate_novol"): sh(f"docker stop {P}cloud"); sh(f"docker rm -v {P}cloud")
        elif mode == "toxi": http("POST", tur + "/proxies/edge-link", {"enabled": False})
        elif mode == "latency":
            http("POST", tur + "/proxies/edge-link/toxics", {"name": "lat", "type": "latency", "stream": "upstream", "toxicity": 1.0, "attributes": {"latency": 2000, "jitter": 0}})
        t_out = time.time()
        if arestart:
            wait(outage / 2); mark("agent_restart"); sh(f"docker restart {P}agent")
            wait_http(aur + "/-/ready"); wait(max(0, outage - (time.time() - t_out)))
        else:
            wait(outage)
        a_pre = metrics(aur + "/metrics")
        mark("outage_end")
        if mode == "stop" or mode == "kill": sh(f"docker start {P}cloud")
        elif mode == "recreate": run_cloud()
        elif mode == "recreate_novol": run_cloud(vol=False)
        elif mode == "toxi": http("POST", tur + "/proxies/edge-link", {"enabled": True})
        elif mode == "latency": http("DELETE", tur + "/proxies/edge-link/toxics/lat")
        t_restore = time.time()
        wait_http(cur + "/-/ready", 120)
        wait(settle)
        mark("measure"); t_end = time.time()
        a_end = metrics(aur + "/metrics"); c_end = metrics(cur + "/metrics")
        clogs = sh(f"docker logs {P}cloud 2>&1 | grep -iE 'out of (bound|order)|error|WARN' | tail -8", check=False)
        alogs = sh(f"docker logs {P}agent 2>&1 | grep -iE 'level=(WARN|ERROR)' | cut -c1-300 | tail -6", check=False)
        # raw samples from cloud
        q = urllib.parse.urlencode({"query": "bf_counter_total[2h]", "time": f"{t_end:.3f}"})
        res = http("GET", cur + "/api/v1/query?" + q)["data"]["result"]
        ts = sorted(float(v[0]) for r in res for v in r["values"])
        # query_range with step=2s: count_over_time over 2s window -> missing steps = empty
        s0 = int(t_start) // 2 * 2; s1 = int(t_end - 5) // 2 * 2
        q = urllib.parse.urlencode({"query": "count_over_time(bf_counter_total[2s])", "start": s0, "end": s1, "step": "2s"})
        rr = http("GET", cur + "/api/v1/query_range?" + q)["data"]["result"]
        have = set(int(float(v[0])) for r in rr for v in r["values"])
        total = (s1 - s0)//2 + 1
        qr_missing = [t for t in range(s0, s1 + 1, 2) if t not in have]
        # regions
        def region(t):
            return "pre" if t < ev[1][1] else ("outage" if t < ev[2][1] else "post")
        # raw gaps: scrape interval 2s; a delta > 3.5s means missing scrapes
        gaps = {"pre": 0, "outage": 0, "post": 0}; maxgap = 0
        firsts = ts[0] if ts else None
        for x, y in zip(ts, ts[1:]):
            d = y - x
            if d > 3.5:
                n = round(d / 2) - 1
                gaps[region(x + 1)] += n; maxgap = max(maxgap, d)
        # history before first sample in cloud (lost pre-outage history for novol)
        lead_missing = round((firsts - t_start) / 2) if firsts else None
        # qr missing by region
        qrg = {"pre": 0, "outage": 0, "post": 0}
        for t in qr_missing: qrg[region(t)] += 1
        gl = []
        for x, y in zip(ts, ts[1:]):
            if y - x > 3.5: gl.append([round(x - ev[1][1], 1), round(y - ev[1][1], 1)])
        out = {"gaps_rel_outage_begin_s": gl, "outage_len_s": round(ev[2][1]-ev[1][1],1), "timeline_t_lag_pending": timeline, "name": name, "params": o, "events": ev, "samples_in_cloud": len(ts),
               "first_sample_delay_vs_start_s": (firsts - t_start) if firsts else None,
               "raw_missing_scrapes_by_region": gaps, "max_gap_s": maxgap,
               "qr_total_steps": total, "qr_missing_steps": len(qr_missing), "qr_missing_by_region": qrg,
               "agent_before_restore": {k: v for k, v in a_pre.items() if any(s in k for s in ("samples_pending", "highest_timestamp", "highest_sent", "samples_failed", "samples_dropped", "samples_retried", "samples_total", "shards"))},
               "agent_end": {k: v for k, v in a_end.items() if any(s in k for s in ("samples_pending", "highest_timestamp", "highest_sent", "samples_failed", "samples_dropped", "samples_retried", "samples_total", "samples_in_total", "sent_batch"))},
               "cloud_end": c_end, "cloud_log": clogs, "agent_log": alogs}
        json.dump(out, open(f"{HERE}/results/{name}.json", "w"), indent=1)
        print(json.dumps({k: out[k] for k in ("name","raw_missing_scrapes_by_region","max_gap_s","qr_missing_steps","qr_missing_by_region","first_sample_delay_vs_start_s")}), flush=True)
    finally:
        if os.environ.get("KEEP") != "1": cleanup()

main()
