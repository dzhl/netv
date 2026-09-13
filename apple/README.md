# neTV for Apple

Native SwiftUI clients for iPhone, iPad, Apple TV, and Mac. All apps share the same authenticated neTV guide, channel artwork, program metadata, and AVPlayer playback while adapting navigation and layout to each platform.

## Open and run

1. Generate the project with `cd apple && xcodegen generate`.
2. Open `apple/neTV.xcodeproj`.
3. Select **neTV-iOS**, **neTV-tvOS**, or **neTV-macOS**, choose a destination, and run.
4. Sign in with the same neTV server address and account used by the web UI.

The development default is `http://localhost:8000`. HTTP transport is enabled because neTV commonly runs on a trusted local network; production deployments should use HTTPS.

## Slow-connection fallback

The Apple app requests fast start for transcoded live channels configured above
720p. One FFmpeg ingest reads the provider and remuxes a rolling local feed; a
720p encoder starts playback while an independent encoder prepares the configured
quality, including AI upscaling. Both encoders read local files, so warming up or
changing quality does not open another provider stream. This requires capacity
for two local encoders and up to roughly two minutes of source segments on disk
(source keyframe spacing can lengthen that window).

The high rendition uses bounded video bitrate: 1080p targets 6 Mbps with an 8 Mbps
peak setting, 1440p targets 10/14 Mbps, and 4K targets 16/20 Mbps. This replaces
unbounded constant-QP encoding for fast-start upgrades, trading compression quality
for predictable bandwidth. Audio and transport overhead are additional; the
upgrade decision still uses measured segment sizes rather than assuming the
encoder setting is an exact network cap. NVENC uses
[variable bitrate control](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/ffmpeg-with-nvidia-gpu/index.html).

Startup waits for at least eight seconds of 720p media (or two source segment
durations, whichever is longer) to bridge bursty upstream delivery. Each rendition
keeps at least the normal 30-second live window. The app requests a 12-second
forward buffer. Channel changes wait for any earlier startup to return its session
ID, then confirm that session has stopped before starting the next provider feed.
Cancelled startup requests therefore cannot leave a second provider reader behind.

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
remains in effect across channel changes until the app restarts; global server
settings are unchanged. Resolution and quality reduction do not impose a
hard network bitrate cap. LTE and dropped-frame counts alone do not trigger fallback.
Direct/passthrough streams do not use this backend feedback mechanism.

To check on a device, play a transcoded live channel and throttle the connection
until it repeatedly runs out of buffer. Check that the high-quality encoder stops
and playback returns to 720p without a second provider connection.
Also check that a short stall or manual pause does not cause a retune, and that tuning
another channel starts with bandwidth saver still enabled. Restarting the app
allows the configured quality to be tried again.

For backend testing on `aitony.tulane`, use the updated Apple app with this branch
on the server. Confirm startup at 720p, upgrade on a healthy connection, continued
720p while the high encoder is unavailable, and cleanup of all three processes
when playback stops. The backend fast-start path is opt-in through
`/transcode/start?fast_start=true`; older clients retain their existing behavior.
The service logs `Playback quality` every ten seconds, including the decision
reason, buffer, measured throughput, high-quality bitrate, and alignment state.

The cancellation/rapid-tuning regression check uses a fake transport with the real
app model. On a Mac, compile and run it with:

```sh
xcrun swiftc -parse-as-library Shared/Models.swift Shared/AppModel.swift Tests/PlaybackStartChecks.swift -o /tmp/netv-playback-start-checks
/tmp/netv-playback-start-checks
```
