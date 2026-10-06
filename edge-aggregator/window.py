"""Pure aggregation logic: tumbling window stats and rolling-RMS alert. No I/O."""
from collections import deque
import math

import numpy as np


class TumblingWindow:
    """Collects samples; close() returns stats and resets. Empty window -> None."""

    def __init__(self, anomaly_threshold=3.0):
        self.anomaly_threshold = anomaly_threshold
        self._values = []
        self._anomalies = 0

    def add(self, value):
        """Add a sample; returns True if it is an anomaly (|v| > threshold)."""
        self._values.append(value)
        is_anom = abs(value) > self.anomaly_threshold
        if is_anom:
            self._anomalies += 1
        return is_anom

    def __len__(self):
        return len(self._values)

    def close(self):
        if not self._values:
            return None
        arr = np.asarray(self._values, dtype=np.float64)
        stats = {
            "count": int(arr.size),
            "mean": float(arr.mean()),
            "min": float(arr.min()),
            "max": float(arr.max()),
            "std": float(arr.std()),  # population std (ddof=0)
            "rms": float(np.sqrt(np.mean(arr * arr))),
            "anomaly_count": self._anomalies,
        }
        self._values = []
        self._anomalies = 0
        return stats


class RollingRMSAlert:
    """Rolling RMS over the last `window_seconds` of sample time.

    update(ts, value) -> (active, changed). Raises when rms > threshold,
    clears when rms <= threshold.
    """

    def __init__(self, threshold=1.5, window_seconds=1.0):
        self.threshold = threshold
        self.window_seconds = window_seconds
        self._buf = deque()  # (ts, value^2)
        self._sumsq = 0.0
        self.active = False

    def rms(self):
        n = len(self._buf)
        if n == 0:
            return 0.0
        return math.sqrt(max(self._sumsq, 0.0) / n)

    def update(self, ts, value):
        sq = value * value
        self._buf.append((ts, sq))
        self._sumsq += sq
        cutoff = ts - self.window_seconds
        while self._buf and self._buf[0][0] <= cutoff:
            self._sumsq -= self._buf.popleft()[1]
        if not self._buf:
            self._sumsq = 0.0
        prev = self.active
        self.active = self.rms() > self.threshold
        return self.active, self.active != prev
