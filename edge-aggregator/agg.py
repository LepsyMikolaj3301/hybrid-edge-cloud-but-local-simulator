"""Edge aggregator: MQTT vibration samples -> window stats + alert -> Prometheus."""
import json
import logging
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import paho.mqtt.client as mqtt
from prometheus_client import (CONTENT_TYPE_LATEST, CollectorRegistry, Counter,
                               Gauge, generate_latest)

from window import RollingRMSAlert, TumblingWindow

TOPIC = "sensors/vibration/raw"
L = {"sensor": "vibration"}

log = logging.getLogger("edge-aggregator")


class Metrics:
    def __init__(self):
        self.registry = CollectorRegistry()
        r = self.registry

        def g(name, doc):
            return Gauge(name, doc, ["sensor"], registry=r).labels(**L)

        def c(name, doc):
            # name given without _total; client appends it
            return Counter(name, doc, ["sensor"], registry=r).labels(**L)

        self.mean = g("edge_window_mean", "Mean of last closed window")
        self.min = g("edge_window_min", "Min of last closed window")
        self.max = g("edge_window_max", "Max of last closed window")
        self.std = g("edge_window_std", "Population std of last closed window")
        self.rms = g("edge_window_rms", "RMS of last closed window")
        self.anomaly_count = g("edge_anomaly_count", "Anomalies in last closed window")
        self.anomalies_total = c("edge_anomalies", "Anomalous samples seen")
        self.alert_active = g("edge_alert_active", "1 if rolling RMS alert active")
        self.alert_ts = g("edge_alert_last_change_timestamp_seconds",
                          "Unix time of last alert flip")
        self.raw_total = c("edge_raw_samples", "Raw samples received")
        self.agg_total = c("edge_aggregates_emitted", "Aggregates emitted")
        self.alert_active.set(0)
        self.alert_ts.set(0)


class Aggregator:
    def __init__(self, metrics, anomaly_threshold, rms_threshold, alert_window):
        self.m = metrics
        self.lock = threading.Lock()
        self.window = TumblingWindow(anomaly_threshold)
        self.alert = RollingRMSAlert(rms_threshold, alert_window)

    def on_sample(self, ts, value):
        with self.lock:
            self.m.raw_total.inc()
            if self.window.add(value):
                self.m.anomalies_total.inc()
            active, changed = self.alert.update(ts, value)
            self.m.alert_active.set(1 if active else 0)
            if changed:
                self.m.alert_ts.set(time.time())
                log.warning("ALERT %s ts=%s rms=%.3f",
                            "RAISED" if active else "CLEARED", ts, self.alert.rms())

    def close_window(self):
        with self.lock:
            s = self.window.close()
            if s is None:
                return None
            m = self.m
            m.mean.set(s["mean"]); m.min.set(s["min"]); m.max.set(s["max"])
            m.std.set(s["std"]); m.rms.set(s["rms"])
            m.anomaly_count.set(s["anomaly_count"])
            m.agg_total.inc()
        log.info("window closed: %s", s)
        return s


def make_handler(registry):
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split("?")[0]
            if path == "/metrics":
                body = generate_latest(registry)
                self.send_response(200)
                self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            elif path == "/healthz":
                body = b"ok\n"
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
            else:
                body = b"not found\n"
                self.send_response(404)
                self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass
    return H


def main():
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    env = os.environ.get
    host = env("MQTT_HOST", "mosquitto.edge.svc")
    port = int(env("MQTT_PORT", "1883"))
    win_s = float(env("WINDOW_SECONDS", "10"))
    agg = Aggregator(Metrics(), float(env("ANOMALY_THRESHOLD", "3.0")),
                     float(env("ALERT_RMS_THRESHOLD", "1.5")),
                     float(env("ALERT_WINDOW_SECONDS", "1")))
    stop = threading.Event()

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="edge-aggregator")

    def on_connect(c, userdata, flags, rc, props=None):
        log.info("MQTT connected rc=%s", rc)
        c.subscribe(TOPIC, qos=0)

    def on_disconnect(c, userdata, flags, rc, props=None):
        log.warning("MQTT disconnected rc=%s", rc)

    def on_message(c, userdata, msg):
        try:
            d = json.loads(msg.payload)
            agg.on_sample(float(d["ts"]), float(d["value"]))
        except (ValueError, KeyError, TypeError):
            log.debug("bad payload %r", msg.payload[:100])

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message
    client.reconnect_delay_set(min_delay=1, max_delay=5)

    def timer():
        nxt = time.monotonic() + win_s
        while not stop.wait(max(0, nxt - time.monotonic())):
            nxt += win_s
            agg.close_window()

    threading.Thread(target=timer, daemon=True).start()

    srv = ThreadingHTTPServer(("0.0.0.0", int(env("METRICS_PORT", "8000"))),
                              make_handler(agg.m.registry))
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    def connect_loop():
        # start even if broker is down; retry until first connect, then loop_start auto-reconnects
        while not stop.is_set():
            try:
                client.connect(host, port, keepalive=30)
                client.loop_start()
                return
            except OSError as e:
                log.warning("MQTT connect failed (%s), retrying", e)
                stop.wait(2)

    threading.Thread(target=connect_loop, daemon=True).start()

    signal.signal(signal.SIGTERM, lambda *a: stop.set())
    signal.signal(signal.SIGINT, lambda *a: stop.set())
    stop.wait()
    client.loop_stop()
    srv.shutdown()


if __name__ == "__main__":
    main()
