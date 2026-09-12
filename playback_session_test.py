"""Verify the fallback changes the actual encoder configuration."""

from unittest.mock import AsyncMock, patch

import pytest

from ffmpeg_session_test import FakeProcess

import ffmpeg_session


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "configured_resolution,expected_resolution", [("4k", "720p"), ("480p", "480p")]
)
async def test_fallback_command_and_cleanup(tmp_path, configured_resolution, expected_resolution):
    settings = {"max_resolution": configured_resolution, "quality": "high", "sr_model": "nomos"}
    with (
        patch("ffmpeg_session.get_settings", return_value=settings),
        patch("ffmpeg_session.get_transcode_dir", return_value=tmp_path),
        patch("ffmpeg_session.resolve_hls_master_playlist", side_effect=lambda url: url),
        patch(
            "ffmpeg_session.build_hls_ffmpeg_cmd", return_value=["ffmpeg", "-i", "stream"]
        ) as command,
        patch(
            "ffmpeg_session.asyncio.create_subprocess_exec",
            new_callable=AsyncMock,
            return_value=FakeProcess(),
        ),
        patch(
            "ffmpeg_session._spawn_background_task", side_effect=lambda coroutine: coroutine.close()
        ),
        patch("ffmpeg_session._wait_for_playlist", new_callable=AsyncMock, return_value=True),
    ):
        result = await ffmpeg_session.start_transcode(
            "http://example.com/live.ts", bandwidth_saver=True
        )
        try:
            assert command.call_args.args[6:8] == (expected_resolution, "low")
            assert command.call_args.kwargs["allow_upscale"] is False
            assert settings == {
                "max_resolution": configured_resolution,
                "quality": "high",
                "sr_model": "nomos",
            }
            assert ffmpeg_session.get_session(result["session_id"])["bandwidth_saver"] is True
        finally:
            ffmpeg_session.stop_session(result["session_id"], force=True)
        assert not list(tmp_path.iterdir())


@pytest.mark.asyncio
async def test_fallback_does_not_reuse_high_quality_stream():
    with (
        patch("ffmpeg_session._get_existing_session", return_value=("old", True, 0)),
        patch("ffmpeg_session.get_session", return_value={"username": "viewer"}),
        patch("ffmpeg_session.stop_session") as stop,
        patch("ffmpeg_session.enforce_stream_limits", return_value=None),
        patch("ffmpeg_session._try_reuse_session", new_callable=AsyncMock) as reuse,
        patch(
            "ffmpeg_session._do_start_transcode",
            new_callable=AsyncMock,
            return_value={"session_id": "new"},
        ) as start,
    ):
        result = await ffmpeg_session.start_transcode(
            "stream", username="viewer", bandwidth_saver=True
        )
    assert result == {"session_id": "new"}
    stop.assert_called_once_with("old", force=True)
    reuse.assert_not_called()
    assert start.call_args.args[-1] is True
