import os, sys
import numpy as np
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from window import RollingRMSAlert, TumblingWindow


def test_stats_match_numpy():
    rng = np.random.default_rng(1)
    vals = rng.normal(0.3, 1.2, 1000)
    w = TumblingWindow(3.0)
    for v in vals:
        w.add(float(v))
    s = w.close()
    assert s["count"] == 1000
    assert s["mean"] == pytest.approx(vals.mean())
    assert s["min"] == pytest.approx(vals.min())
    assert s["max"] == pytest.approx(vals.max())
    assert s["std"] == pytest.approx(np.std(vals, ddof=0))
    assert s["rms"] == pytest.approx(np.sqrt(np.mean(vals ** 2)))


def test_anomaly_threshold_boundary():
    w = TumblingWindow(3.0)
    assert w.add(3.0) is False
    assert w.add(-3.0) is False
    assert w.add(3.0001) is True
    assert w.add(-3.5) is True
    assert w.close()["anomaly_count"] == 2


def test_rollover_resets():
    w = TumblingWindow(3.0)
    w.add(5.0); w.add(1.0)
    assert w.close()["anomaly_count"] == 1
    w.add(2.0)
    s = w.close()
    assert s["count"] == 1 and s["anomaly_count"] == 0 and s["mean"] == 2.0
    assert len(w) == 0


def test_empty_window_returns_none():
    assert TumblingWindow().close() is None


def test_alert_raise_and_clear():
    a = RollingRMSAlert(threshold=1.5, window_seconds=1.0)
    t = 0.0
    flips = []
    for _ in range(100):  # quiet 1 s
        t += 0.01
        act, ch = a.update(t, 0.1)
        assert not act
    for _ in range(100):  # loud 1 s
        t += 0.01
        act, ch = a.update(t, 5.0)
        if ch:
            flips.append(("raise", t))
    assert a.active and len(flips) == 1
    burst_end = t
    for _ in range(150):
        t += 0.01
        act, ch = a.update(t, 0.1)
        if ch:
            flips.append(("clear", t))
    assert not a.active
    assert [f[0] for f in flips] == ["raise", "clear"]
    # clears within about the window length after the burst ends
    assert 0 < flips[1][1] - burst_end <= 1.0


def test_alert_rms_uses_only_window():
    a = RollingRMSAlert(1.5, 1.0)
    a.update(0.0, 10.0)
    a.update(2.0, 0.0)  # old sample evicted
    assert a.rms() == 0.0 and not a.active


def test_single_spike_does_not_alert():
    a = RollingRMSAlert(1.5, 1.0)
    for i in range(100):
        a.update(i * 0.01, 6.0 if i == 50 else 0.1)
    assert not a.active
