import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import pytest

pytest.importorskip("paho.mqtt.client")
from prometheus_client import generate_latest
from agg import Aggregator, Metrics


def val(m, name):
    return m.registry.get_sample_value(name, {"sensor": "vibration"})


def make():
    m = Metrics()
    return m, Aggregator(m, 3.0, 1.5, 1.0)


def test_counters_and_empty_window():
    m, a = make()
    assert a.close_window() is None
    assert val(m, "edge_aggregates_emitted_total") == 0
    for i, v in enumerate([0.1, 4.0, -4.0, 3.0]):
        a.on_sample(i * 0.01, v)
    assert val(m, "edge_raw_samples_total") == 4
    assert val(m, "edge_anomalies_total") == 2
    s = a.close_window()
    assert s["count"] == 4
    assert val(m, "edge_aggregates_emitted_total") == 1
    assert val(m, "edge_anomaly_count") == 2
    assert val(m, "edge_window_max") == 4.0
    assert a.close_window() is None
    assert val(m, "edge_aggregates_emitted_total") == 1
    assert val(m, "edge_anomalies_total") == 2  # total persists, per-window gauge stays


def test_alert_metrics_flip():
    m, a = make()
    for i in range(100):
        a.on_sample(i * 0.01, 5.0)
    assert val(m, "edge_alert_active") == 1
    assert val(m, "edge_alert_last_change_timestamp_seconds") > 1e9
    for i in range(100, 250):
        a.on_sample(i * 0.01, 0.0)
    assert val(m, "edge_alert_active") == 0


def test_exposition_names():
    m, _ = make()
    out = generate_latest(m.registry).decode()
    for n in ["edge_window_mean", "edge_window_rms", "edge_raw_samples_total",
              'edge_alert_active{sensor="vibration"}']:
        assert n in out
