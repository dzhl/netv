"""Fast start must keep one upstream reader and survive a failed high encoder."""

from unittest.mock import AsyncMock, patch

import os
import pathlib
import shutil
import subprocess

import pytest

from ffmpeg_session_test import FakeProcess
from playback_policy import PlaybackHealth, PlaybackPolicy

import fast_start
import ffmpeg_session


def video_packet(seconds):
    pts = int(seconds * 90000)
    encoded = bytes(
        [
            0x21 | ((pts >> 29) & 14),
            (pts >> 22) & 255,
            ((pts >> 14) & 254) | 1,
            (pts >> 7) & 255,
            ((pts << 1) & 254) | 1,
        ]
    )
    pes = b"\x00\x00\x01\xe0\x00\x00\x80\x80\x05" + encoded
    return (b"\x47\x41\x00\x10" + pes).ljust(188, b"\xff")


def playlist(directory, name, start=10):
    lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:2"]
    for i in range(3):
        filename = f"{name}_{i}.ts"
        (directory / filename).write_bytes(video_packet(start + i * 2) * 10)
        lines += ["#EXTINF:2,", filename]
    (directory / f"{name}.m3u8").write_text("\n".join(lines) + "\n")


def test_timeline_and_readiness(tmp_path):
    playlist(tmp_path, "low")
    playlist(tmp_path, "high")
    assert fast_start.aligned(str(tmp_path))
    assert fast_start.ready_bitrate(str(tmp_path), "high.m3u8") == 7520
    assert fast_start.segment_pts(tmp_path / "low_0.ts") == 10
    content = (tmp_path / "high.m3u8").read_text()
    dated = fast_start.dated_playlist(str(tmp_path), content, 10, 0)
    assert "#EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000+00:00" in dated
    playlist(tmp_path, "high", start=0)
    assert not fast_start.aligned(str(tmp_path))
    os.utime(tmp_path / "high.m3u8", (0, 0))
    assert fast_start.ready_bitrate(str(tmp_path), "high.m3u8") == 0
    (tmp_path / "low_2.ts").unlink()
    assert fast_start.ready_bitrate(str(tmp_path), "low.m3u8") == 0


def test_commands_only_ingest_opens_provider(tmp_path):
    url = "https://provider.example/live.ts"
    ingest = fast_start.ingest_command(url, str(tmp_path), "neTV")
    assert ingest[ingest.index("-i") + 1] == url
    for high in (False, True):
        cmd = fast_start.encoder_command(
            str(tmp_path), "software", "1080p" if high else "720p", "low", False, high
        )
        assert url not in cmd
        assert cmd[cmd.index("-i") + 1] == f"{tmp_path}/input.m3u8"
        assert "-reconnect" not in cmd
        assert "-copyts" in cmd


def test_upgrade_requires_sustained_headroom_and_fallback_latches(tmp_path):
    playlist(tmp_path, "low")
    playlist(tmp_path, "high")
    high = FakeProcess()
    session = dict(
        dir=str(tmp_path),
        username="u",
        fast_start=True,
        high_process=high,
        playback_policy=PlaybackPolicy(),
    )
    good = PlaybackHealth(buffer_seconds=10, waiting=False, observed_bitrate=20000)
    weak = PlaybackHealth(buffer_seconds=10, waiting=False, observed_bitrate=8000)
    with (
        patch.dict(ffmpeg_session._transcode_sessions, {"fast": session}),
        patch("ffmpeg_session.time.monotonic") as clock,
    ):
        for now in (0, 2, 4, 6):
            clock.return_value = now
            result = ffmpeg_session.report_playback_health("fast", "u", weak)
            assert result["playlist"].endswith("/low.m3u8")
        for now in (8, 10, 12):
            clock.return_value = now
            assert ffmpeg_session.report_playback_health("fast", "u", good)["playlist"].endswith(
                "/low.m3u8"
            )
        clock.return_value = 14
        assert ffmpeg_session.report_playback_health("fast", "u", good)["playlist"].endswith(
            "/high.m3u8"
        )
        session["playback_policy"].bandwidth_saver = True
        clock.return_value = 16
        result = ffmpeg_session.report_playback_health("fast", "u", good)
        assert result["bandwidth_saver"]
        assert result["playlist"].endswith("/low.m3u8")
        assert high.returncode == -15


@pytest.mark.asyncio
@pytest.mark.parametrize("fail_high", [False, True])
async def test_shared_session_cleanup(tmp_path, fail_high):
    launched = []

    async def launch(*cmd, **kwargs):
        if fail_high and len(launched) == 2:
            raise OSError("no encoder")
        process = FakeProcess()
        launched.append((cmd, process))
        return process

    def ready(directory, name):
        if name == "input.m3u8":
            (pathlib.Path(directory) / "input_0.ts").write_bytes(video_packet(10))
        return 10000

    with (
        patch("ffmpeg_session.get_settings", return_value={"max_resolution": "4k"}),
        patch("ffmpeg_session.get_transcode_dir", return_value=tmp_path),
        patch("ffmpeg_session.asyncio.create_subprocess_exec", side_effect=launch),
        patch("ffmpeg_session._spawn_background_task", side_effect=lambda coro: coro.close()),
        patch("ffmpeg_session.ready_bitrate", side_effect=ready),
    ):
        result = await ffmpeg_session.start_transcode("https://provider/live", fast_start=True)
        assert result["playlist"].endswith("/low.m3u8")
        assert sum("https://provider/live" in cmd for cmd, _ in launched) == 1
        ffmpeg_session.stop_session(result["session_id"], force=True)
        assert all(proc.returncode is not None for _, proc in launched)
        assert not list(tmp_path.iterdir())


@pytest.mark.asyncio
async def test_startup_cancellation_cleans_ingest(tmp_path):
    import asyncio

    proc = FakeProcess()
    with (
        patch("ffmpeg_session.get_settings", return_value={"max_resolution": "4k"}),
        patch("ffmpeg_session.get_transcode_dir", return_value=tmp_path),
        patch("ffmpeg_session.asyncio.create_subprocess_exec", new=AsyncMock(return_value=proc)),
        patch("ffmpeg_session._spawn_background_task", side_effect=lambda coro: coro.close()),
        patch("ffmpeg_session.ready_bitrate", side_effect=asyncio.CancelledError),
    ):
        with pytest.raises(asyncio.CancelledError):
            await ffmpeg_session.start_transcode("https://provider/cancel", fast_start=True)
        assert proc.returncode is not None
        assert not list(tmp_path.iterdir())


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="requires FFmpeg")
def test_real_local_encoders_share_timestamps(tmp_path):
    """Exercise the actual generated commands, demuxing, and timestamp extraction."""
    source = tmp_path / "source.ts"
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=320x180:rate=25",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=48000",
            "-t",
            "12",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-g",
            "25",
            "-c:a",
            "aac",
            str(source),
        ],
        check=True,
    )
    subprocess.run(fast_start.ingest_command(str(source), str(tmp_path), None), check=True)
    processes = [
        subprocess.Popen(
            fast_start.encoder_command(str(tmp_path), "software", "720p", "low", False, high),
            stderr=subprocess.PIPE,
        )
        for high in (False, True)
    ]
    try:
        for process in processes:
            _, error = process.communicate(timeout=30)
            assert process.returncode == 0, error.decode()
        assert fast_start.ready_bitrate(str(tmp_path), "low.m3u8") > 0
        assert fast_start.ready_bitrate(str(tmp_path), "high.m3u8") > 0
        assert fast_start.aligned(str(tmp_path))
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
            process.wait()
