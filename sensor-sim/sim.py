import json
import math
import os
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

import paho.mqtt.client as mqtt

MQTT_HOST = os.getenv("MQTT_HOST", "mosquitto.edge.svc")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
RATE = float(os.getenv("SAMPLE_RATE_HZ", "100"))
FREQ = float(os.getenv("SIGNAL_FREQ_HZ", "0.5"))
AMP = float(os.getenv("SIGNAL_AMPLITUDE", "1.0"))
NOISE = float(os.getenv("NOISE_STD", "0.1"))
ANOM_RATE = float(os.getenv("ANOMALY_RATE", "0.001"))
ANOM_AMP = float(os.getenv("ANOMALY_AMPLITUDE", "6.0"))
HTTP_PORT = int(os.getenv("HTTP_PORT", "8080"))
RAW = "sensors/vibration/raw"
CTRL = "sensors/vibration/control"
BURST_P = 0.3

connected = threading.Event()
lock = threading.Lock()
burst = {"until": 0.0, "amp": 0.0}  # monotonic deadline


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="sensor-sim")


def on_connect(c, u, flags, rc, props):
    if rc == 0:
        connected.set()
        c.subscribe(CTRL, qos=0)
        log(f"mqtt connected {MQTT_HOST}:{MQTT_PORT}")
    else:
        log(f"mqtt connect failed rc={rc}")


def on_disconnect(c, u, flags, rc, props):
    connected.clear()
    log(f"mqtt disconnected rc={rc}")


def on_message(c, u, msg):
    try:
        d = json.loads(msg.payload)
        if d.get("cmd") != "burst":
            return
        dur = float(d.get("duration_s", 5))
        amp = float(d.get("amplitude", 8.0))
    except Exception as e:
        log(f"bad control message: {e}")
        return
    with lock:
        burst["until"] = time.monotonic() + dur
        burst["amp"] = amp
    log(f"burst start duration_s={dur} amplitude={amp}")


client.on_connect = on_connect
client.on_disconnect = on_disconnect
client.on_message = on_message
client.reconnect_delay_set(min_delay=1, max_delay=5)


def mqtt_start():
    # connect_async + loop_start retries automatically even if broker is down
    client.connect_async(MQTT_HOST, MQTT_PORT, keepalive=30)
    client.loop_start()


class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if urlparse(self.path).path == "/healthz":
            ok = connected.is_set()
            self._send(200 if ok else 503, {"status": "ok" if ok else "mqtt disconnected"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        u = urlparse(self.path)
        if u.path != "/burst":
            return self._send(404, {"error": "not found"})
        q = parse_qs(u.query)
        try:
            dur = float(q.get("duration_s", ["5"])[0])
            amp = float(q.get("amplitude", ["8"])[0])
        except ValueError:
            return self._send(400, {"error": "invalid parameters"})
        if dur <= 0 or dur > 3600:
            return self._send(400, {"error": "duration_s must be in (0, 3600]"})
        msg = {"cmd": "burst", "duration_s": dur, "amplitude": amp}
        info = client.publish(CTRL, json.dumps(msg), qos=0)
        if info.rc != mqtt.MQTT_ERR_SUCCESS or not connected.is_set():
            return self._send(503, {"error": "mqtt unavailable"})
        self._send(200, {"published": msg, "topic": CTRL})

    def log_message(self, *a):
        pass


def main():
    log(f"start rate={RATE}Hz freq={FREQ} amp={AMP} noise={NOISE} "
        f"anomaly_rate={ANOM_RATE} anomaly_amp={ANOM_AMP} http={HTTP_PORT}")
    mqtt_start()
    srv = ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    period = 1.0 / RATE
    t0 = time.monotonic()
    n = 0
    in_burst = False
    while True:
        n += 1
        target = t0 + n * period
        delay = target - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        elif delay < -1.0:  # fell far behind: resync rather than flood
            t0 = time.monotonic() - n * period
        now = time.monotonic()
        t = n * period
        v = AMP * math.sin(2 * math.pi * FREQ * t) + random.gauss(0, NOISE)
        if random.random() < ANOM_RATE:
            v += random.choice((-1, 1)) * ANOM_AMP
        with lock:
            bu, ba = burst["until"], burst["amp"]
        active = now < bu
        if active and random.random() < BURST_P:
            v += random.choice((-1, 1)) * ba
        if in_burst and not active:
            log("burst end")
        in_burst = active
        if connected.is_set():
            client.publish(RAW, json.dumps({"ts": time.time(), "value": v}), qos=0)


if __name__ == "__main__":
    main()
