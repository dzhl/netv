# neTV for Apple

Native SwiftUI clients for iPhone, iPad, Apple TV, and Mac. All apps share the same authenticated neTV guide, channel artwork, program metadata, and AVPlayer playback while adapting navigation and layout to each platform.

Mac and Apple TV share the same live layout and slate/purple color scheme, with
larger text and controls on TV. A narrow Live TV / Settings navigation rail sits
beside a full-height category column with its own scrollbar. Categories stay
visible while the adjacent channel list scrolls, and a single click switches
categories locally without waiting for a network request. Category names appear
only once: names differing only in case or surrounding whitespace are grouped,
and selecting a group includes channels from all of its underlying category IDs.
The first occurrence determines the displayed name and order.

The guide uses compact logo-led channel rows, purple current-program highlights,
half-hour time markers, and a now indicator. A small video preview occupies the
top-right corner, with the channel, program title, times, and description beside
it across the top; the channel guide is below. Selecting a category only filters
the list; selecting a channel tunes playback. Search covers channel names and all
loaded program titles, and channel counts follow the search.

On TV, the navigation rail also has Search and Refresh controls. Full Screen
hides the rail and category/guide panels and lets the player fill the display,
including the usual tvOS safe-area margins. Video retains its original aspect
ratio. Back/Menu returns to the guide without restarting playback, preserving
the selected category and scroll position. The remote's Play/Pause button still
works without showing a transport overlay.

Neither Mac nor TV displays a native play/pause toolbar or full-width title
overlay. Volume lives in a small bottom-left panel whose translucent background
is limited to that panel: a slider on Mac and remote-focusable minus/plus buttons
on TV. These adjust the app's audio level; the Siri Remote's hardware volume keys
still control the connected TV/receiver. App volume carries across channel
changes and adaptive quality switches. Full-screen controls remain inset from
the screen edges while the video itself uses the full display.

Category names and ordering follow the web settings. Use the updated neTV server
for category metadata and device-local program times; older servers remain
playable through All Channels. The Apple client loads every guide page rather
than stopping at the first 500 channels. Use the refresh button to reload
channels and the three-hour schedule.

## Open and run

1. Generate the project with `cd apple && xcodegen generate`.
2. Open `apple/neTV.xcodeproj`.
3. Select **neTV-iOS**, **neTV-tvOS**, or **neTV-macOS**, choose a destination, and run.
4. Sign in with the same neTV server address and account used by the web UI.

The development default is `http://localhost:8000`. HTTP transport is enabled because neTV commonly runs on a trusted local network; production deployments should use HTTPS.

## Shared adaptive live playback

The Apple app and web player request the same fast-start backend for transcoded
live channels configured above 720p. One FFmpeg ingest reads the provider and
remuxes a rolling local feed; a
720p encoder builds the startup reserve first, then an independent encoder starts
preparing the configured quality, including AI upscaling. This keeps high-quality
GPU initialization out of initial buffer preparation, at the cost of a later
quality upgrade. Playback does not wait for high-quality output.
Both encoders read local files, so warming up or changing quality does not open
another provider stream. This requires capacity
for two local encoders and up to roughly two minutes of source segments on disk
(source keyframe spacing can lengthen that window).

The 720p rendition targets 4 Mbps with a 6 Mbps peak setting. The high rendition
uses the same shared bitrate policy: 1080p targets 6 Mbps with an 8 Mbps
peak setting, 1440p targets 10/14 Mbps, and 4K targets 16/20 Mbps. This replaces
unbounded constant-QP encoding for adaptive live playback, trading compression quality
for predictable bandwidth. Audio and transport overhead are additional; the
upgrade decision still uses measured segment sizes rather than assuming the
encoder setting is an exact network cap. NVENC uses
[variable bitrate control](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/ffmpeg-with-nvidia-gpu/index.html).
The standard live AI-upscale encoder used by the native gateway shares these
limits too; VOD encoding retains its existing quality settings.

Ingest limits initial FFmpeg analysis to one second of media and starts the local
720p encoder as soon as one complete source segment is available, rather than waiting
for a second source keyframe interval before encoder warm-up. It retains probed
packets; `nobuffer` is deliberately not used because dropping those packets can
delay the first decodable frame. Logs report elapsed time to input readiness and
720p readiness separately.

Playback still waits for at least eight seconds of 720p media (or two source segment
durations, whichever is longer) to bridge bursty upstream delivery. Each rendition
keeps at least the normal 30-second live window. The app requests a 12-second
forward buffer. Apple channel changes and in-page web restarts wait for any earlier
startup to return its session ID, then confirm that session has stopped before
starting the next provider feed. The backend checks for disconnected requests while
waiting for adaptive startup and cleans up their processes and files.

The web player consumes a local master playlist containing the same low/high
renditions. Hls.js starts pinned to low quality, reports buffer and recent fragment
download measurements every two seconds, and follows the backend's health decisions
using in-place level switching. Both playlists carry matching program dates; the
web player does not reload the source or open another provider stream on upgrades.
It targets a 12-second live delay when enough media is available, rather than
treating transcoded live streams as VOD. Native browser HLS without Hls.js telemetry
stays on the initial rendition and only sends heartbeats.

An upgrade requires fresh high-quality segments caught up to the low rendition,
at least six seconds of player buffer, and three download measurements spanning
at least six seconds with 50% headroom over the largest recent high-quality
segment bitrate. Measurements expire after ten seconds; polls with no download
do not erase recent evidence. Encoder readiness is checked when switching rather
than requiring continuous alignment throughout each source delivery burst.
Unavailable throughput leaves playback at 720p. Shared MPEG-TS timestamps produce matching
playlist dates; the app prepares the replacement while playback continues and
seeks to the current broadcast time before switching. A brief buffering pause is
still possible. A failed high-quality encoder leaves 720p available.

For live playback using neTV's transcoder (`transcode_mode: always`), the Apple app
reports buffer level, waiting state, and recent download throughput every two seconds.
After a 15-second startup grace period, the backend requests bandwidth saver if the
buffer remains below three seconds and playback is waiting or downloads cannot keep
up for eight seconds. Pauses and brief stalls do not trigger it.

Fast-start sessions switch back to their local 720p rendition and stop the high
encoder. Other sessions stop and retune with AI upscaling disabled, a 720p maximum
(480p if already configured), and the low encoder quality preset. Bandwidth saver
remains in effect across channel changes until the Apple app restarts; the web
player evaluates each new channel session afresh. Global server settings are
unchanged. Legacy single-rendition fallback reduces resolution and quality without
imposing the adaptive rendition's bitrate limits. LTE and dropped-frame counts
alone do not trigger fallback.
Direct/passthrough streams do not use this backend feedback mechanism.

An upstream advertising `m3u8` supports HLS, but not necessarily adaptive bitrate.
Confirm multiple `#EXT-X-STREAM-INF` variants in a channel's master playlist before
assuming provider-side adaptation is available. A media playlist with only
`#EXTINF` segments is a single rendition. Inspect provider playlists only when a
connection slot is free: even a playlist request can count as a stream on
single-connection accounts. The fast-start path creates its two qualities locally;
it does not implement provider-side adaptive bitrate switching. Its ingest already
avoids a separate `ffprobe` connection regardless of the `probe_live` setting.

To check on a device, play a transcoded live channel and throttle the connection
until it repeatedly runs out of buffer. Check that the high-quality encoder stops
and playback returns to 720p without a second provider connection.
Also check that a short stall or manual pause does not cause a retune, and that tuning
another channel starts with bandwidth saver still enabled. Restarting the app
allows the configured quality to be tried again.

For backend testing on `aitony.tulane`, use the updated Apple app with this branch
on the server, or reload the web player after restarting the updated backend.
Confirm startup at 720p, upgrade on a healthy connection, continued
720p while the high encoder is unavailable, and cleanup of all three processes
when playback stops. The backend fast-start path is selected by both clients through
`/transcode/start?fast_start=true`; older clients and gateway players retain their existing
playback contracts. The response includes `playlist` for the initial rendition and
`master_playlist` for clients that switch HLS levels in place.
The service logs `Playback quality` every ten seconds, including the decision
reason, buffer, measured throughput, high-quality bitrate, and alignment state.

The cancellation/rapid-tuning regression check uses a fake transport with the real
app model. On a Mac, compile and run it with:

```sh
xcrun swiftc -parse-as-library Shared/Models.swift Shared/AppModel.swift Tests/PlaybackStartChecks.swift -o /tmp/netv-playback-start-checks
/tmp/netv-playback-start-checks
```

The guide decoding and timeline checks run separately:

```sh
xcrun swiftc -parse-as-library Shared/Models.swift Tests/GuideDataChecks.swift -o /tmp/netv-guide-checks
/tmp/netv-guide-checks
```
