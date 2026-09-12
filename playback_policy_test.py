"""Playback fallback should react to sustained pressure, not transient stalls."""

from pydantic import ValidationError

import pytest

from playback_policy import PlaybackHealth, PlaybackPolicy


def health(*, buffer=0, waiting=True, observed=0, required=0):
    return PlaybackHealth(
        buffer_seconds=buffer,
        waiting=waiting,
        observed_bitrate=observed,
        required_bitrate=required,
    )


def test_startup_grace_and_sustained_stall_then_latched_fallback():
    policy = PlaybackPolicy()
    for now in range(0, 24, 2):
        assert not policy.observe(health(), now)
    assert policy.observe(health(), 24)
    assert policy.observe(health(buffer=30, waiting=False), 26)


def test_low_throughput_with_dwindling_buffer_triggers_fallback():
    policy = PlaybackPolicy()
    slow = health(buffer=2, waiting=False, observed=1_000_000, required=4_000_000)
    for now in range(0, 24, 2):
        assert not policy.observe(slow, now)
    assert policy.observe(slow, 24)


@pytest.mark.parametrize(
    "sample",
    [
        health(buffer=20, observed=1_000_000, required=4_000_000),
        health(waiting=False),  # Paused, or throughput unavailable.
        health(waiting=False, observed=10_000_000, required=4_000_000),
    ],
)
def test_healthy_or_unknown_samples_do_not_trigger(sample):
    policy = PlaybackPolicy()
    assert not any(policy.observe(sample, now) for now in range(0, 60, 2))


def test_short_stall_and_pause_reset_evidence():
    policy = PlaybackPolicy()
    for now in range(0, 22, 2):
        assert not policy.observe(health(), now)
    assert not policy.observe(health(waiting=False), 22)
    for now in range(24, 32, 2):
        assert not policy.observe(health(), now)
    assert policy.observe(health(), 32)


def test_background_gap_resets_evidence():
    policy = PlaybackPolicy()
    for now in range(0, 22, 2):
        assert not policy.observe(health(), now)
    assert not policy.observe(health(), 100)
    for now in range(102, 108, 2):
        assert not policy.observe(health(), now)
    assert policy.observe(health(), 108)


@pytest.mark.parametrize("value", [-1, float("nan"), float("inf")])
def test_invalid_metrics_rejected(value):
    with pytest.raises(ValidationError):
        health(buffer=value)
    with pytest.raises(ValidationError):
        health(observed=value)
