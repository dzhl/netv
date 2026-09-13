"""Single upstream ingest and independent local encoders for live fast start."""

from datetime import UTC, datetime

import pathlib
import re
import time

from ffmpeg_command import build_hls_ffmpeg_cmd, get_live_hls_list_size


def ingest_command(url: str, directory: str, user_agent: str | None) -> list[str]:
    # Remux only. No probe subprocess and no encoder may open the provider URL.
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error"]
    if url.startswith(("http://", "https://")):
        cmd += [
            "-reconnect",
            "1",
            "-reconnect_streamed",
            "1",
            "-reconnect_on_network_error",
            "1",
            "-reconnect_on_http_error",
            "4xx,5xx",
            "-reconnect_delay_max",
            "5",
        ]
    if user_agent:
        cmd += ["-user_agent", user_agent]
    return cmd + [
        "-i",
        url,
        "-map",
        "0:v:0",
        "-map",
        "0:a:0",
        "-c",
        "copy",
        "-f",
        "hls",
        "-hls_time",
        "1",
        "-hls_list_size",
        "120",
        "-hls_flags",
        "delete_segments+temp_file",
        "-hls_segment_filename",
        f"{directory}/input_%06d.ts",
        f"{directory}/input.m3u8",
    ]


def encoder_command(
    directory: str, hw: str, resolution: str, quality: str, deinterlace: bool, high: bool
) -> list[str]:
    cmd = build_hls_ffmpeg_cmd(
        f"{directory}/input.m3u8",
        hw,
        directory,
        False,
        [],
        None,
        resolution,
        quality,
        None,
        deinterlace,
        allow_upscale=high,
    )
    # HTTP reconnect flags do not apply to the local HLS input.
    for flag in (
        "-reconnect",
        "-reconnect_streamed",
        "-reconnect_on_network_error",
        "-reconnect_on_http_error",
        "-reconnect_delay_max",
    ):
        index = cmd.index(flag)
        del cmd[index : index + 2]
    index = cmd.index("-i")
    cmd[index:index] = ["-live_start_index", "0"]
    cmd[cmd.index("-probesize") + 1] = "500000"
    cmd[cmd.index("-analyzeduration") + 1] = "500000"
    # Preserve the shared source timeline through both independent encoders.
    cmd[1:1] = ["-copyts"]
    prefix = "high" if high else "low"
    cmd[cmd.index("-hls_segment_filename") + 1] = f"{directory}/{prefix}_%06d.ts"
    cmd[cmd.index("-hls_flags") + 1] = "delete_segments+temp_file"
    duration = "2"
    cmd[cmd.index("-hls_time") + 1] = duration
    cmd[cmd.index("-hls_list_size") + 1] = str(get_live_hls_list_size(float(duration)))
    cmd[-1:-1] = [
        "-force_key_frames",
        f"expr:if(isnan(prev_forced_t),1,gte(t,prev_forced_t+{duration}))",
    ]
    cmd[-1] = f"{directory}/{prefix}.m3u8"
    return cmd


def playlist_duration(directory: str, name: str) -> float:
    try:
        content = (pathlib.Path(directory) / name).read_text()
        return sum(float(value) for value in re.findall(r"#EXTINF:([\d.]+)", content))
    except (OSError, ValueError):
        return 0


def segment_pts(path: pathlib.Path) -> float | None:
    """First video PES presentation timestamp in an MPEG-TS segment, in seconds."""
    try:
        with path.open("rb") as source:
            data = source.read(188 * 512)
    except OSError:
        return None
    for offset in range(0, len(data) - 187, 188):
        packet = data[offset : offset + 188]
        if packet[0] != 0x47 or not packet[1] & 0x40:
            continue
        control = (packet[3] >> 4) & 3
        if control not in (1, 3):
            continue
        start = 4 if control == 1 else 5 + packet[4]
        pes = packet[start:]
        if len(pes) < 14 or pes[:3] != b"\x00\x00\x01" or not 0xE0 <= pes[3] <= 0xEF:
            continue
        if not pes[7] & 0x80:
            continue
        p = pes[9:14]
        pts = (p[0] >> 1 & 7) << 30 | p[1] << 22 | (p[2] >> 1) << 15 | p[3] << 7 | p[4] >> 1
        return pts / 90000
    return None


def dated_playlist(directory: str, content: str, origin_pts: float, origin_time: float) -> str:
    """Map both renditions to the same clock, independent of encoder warm-up."""
    lines = content.splitlines()
    result = []
    for line in lines:
        if line and not line.startswith("#") and pathlib.Path(line).name == line:
            pts = segment_pts(pathlib.Path(directory) / line)
            if pts is not None:
                elapsed = (pts - origin_pts) % ((1 << 33) / 90000)
                date = datetime.fromtimestamp(origin_time + elapsed, UTC)
                result.append("#EXT-X-PROGRAM-DATE-TIME:" + date.isoformat(timespec="milliseconds"))
        result.append(line)
    return "\n".join(result) + "\n"


def aligned(directory: str) -> bool:
    """Do not promote an encoder that is still catching up with the low rendition."""
    try:
        ends = []
        for name in ("low.m3u8", "high.m3u8"):
            content = (pathlib.Path(directory) / name).read_text()
            entries = re.findall(r"#EXTINF:([\d.]+),[^\n]*\n([^#\n]+)", content)
            duration, filename = entries[-1]
            pts = segment_pts(pathlib.Path(directory) / filename)
            if pts is None:
                return False
            ends.append(pts + float(duration))
        return abs(ends[0] - ends[1]) <= 3
    except (OSError, ValueError, IndexError):
        return False


def ready_bitrate(directory: str, name: str) -> float:
    """Require complete, fresh segments; use the largest recent segment bitrate."""
    path = pathlib.Path(directory) / name
    try:
        if time.time() - path.stat().st_mtime > 10:
            return 0
        entries = re.findall(r"#EXTINF:([\d.]+),[^\n]*\n([^#\n]+)", path.read_text())
        if len(entries) < 2:
            return 0
        rates = []
        for duration, filename in entries[-3:]:
            if pathlib.Path(filename).name != filename or float(duration) <= 0:
                return 0
            size = (path.parent / filename).stat().st_size
            if size < 1000:
                return 0
            rates.append(size * 8 / float(duration))
        return max(rates)
    except (OSError, ValueError):
        return 0
