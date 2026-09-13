"""Conservative, one-way quality fallback for live playback."""

from dataclasses import dataclass, field

from pydantic import BaseModel, Field


class PlaybackHealth(BaseModel):
    buffer_seconds: float = Field(ge=0, le=86400, allow_inf_nan=False)
    waiting: bool
    # Zero means unavailable. The client supplies a recent download sample.
    observed_bitrate: float = Field(default=0, ge=0, le=1e12, allow_inf_nan=False)
    required_bitrate: float = Field(default=0, ge=0, le=1e12, allow_inf_nan=False)


@dataclass
class PlaybackPolicy:
    started: float | None = None
    last_sample: float | None = None
    unhealthy_since: float | None = None
    bandwidth_saver: bool = False

    def observe(self, health: PlaybackHealth, now: float) -> bool:
        if self.bandwidth_saver:
            return True
        if self.started is None:
            self.started = now
        # A backgrounded/paused client must establish fresh evidence on return.
        if self.last_sample is not None and now - self.last_sample > 10:
            self.unhealthy_since = None
        self.last_sample = now
        slow_download = (
            health.required_bitrate > 0
            and 0 < health.observed_bitrate < health.required_bitrate * 1.2
        )
        unhealthy = health.buffer_seconds < 3 and (health.waiting or slow_download)
        # Allow initial tuning and buffering to settle before making a decision.
        if now - self.started < 15 or not unhealthy:
            self.unhealthy_since = None
        elif self.unhealthy_since is None:
            self.unhealthy_since = now
        elif now - self.unhealthy_since >= 8:
            self.bandwidth_saver = True
        return self.bandwidth_saver


@dataclass
class UpgradePolicy:
    """Keep recent capacity evidence across HLS download and encoder batching gaps."""

    samples: list[tuple[float, float]] = field(default_factory=list)
    reason: str = "waiting for throughput"

    def observe(
        self, health: PlaybackHealth, target_bitrate: float, ready: bool, now: float
    ) -> bool:
        self.samples = [(at, rate) for at, rate in self.samples if now - at <= 10]
        if health.waiting or health.buffer_seconds < 3:
            self.samples.clear()
            self.reason = "playback pressure"
            return False
        # Zero means no transfer measurement, not zero available bandwidth.
        if health.observed_bitrate > 0:
            if target_bitrate > 0 and health.observed_bitrate < target_bitrate * 1.5:
                self.samples.clear()
                self.reason = "insufficient bandwidth headroom"
                return False
            self.samples.append((now, health.observed_bitrate))
        if target_bitrate <= 0:
            self.reason = "4K segments unavailable"
        elif any(rate < target_bitrate * 1.5 for _, rate in self.samples):
            self.reason = "insufficient bandwidth headroom"
        elif len(self.samples) < 3 or self.samples[-1][0] - self.samples[0][0] < 6:
            self.reason = "waiting for throughput evidence"
        elif health.buffer_seconds < 6:
            self.reason = "building playback buffer"
        elif not ready:
            self.reason = "high-quality encoder catching up"
        else:
            self.reason = "ready"
            return True
        return False
