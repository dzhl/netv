# neTV for Apple

Native SwiftUI clients for iPhone, iPad, Apple TV, and Mac. All apps share the same authenticated neTV guide, channel artwork, program metadata, and AVPlayer playback while adapting navigation and layout to each platform.

## Open and run

1. Generate the project with `cd apple && xcodegen generate`.
2. Open `apple/neTV.xcodeproj`.
3. Select **neTV-iOS**, **neTV-tvOS**, or **neTV-macOS**, choose a destination, and run.
4. Sign in with the same neTV server address and account used by the web UI.

The development default is `http://localhost:8000`. HTTP transport is enabled because neTV commonly runs on a trusted local network; production deployments should use HTTPS.

## Slow-connection fallback

For live playback using neTV's transcoder (`transcode_mode: always`), the Apple app
reports buffer level, waiting state, and recent download throughput every two seconds.
After a 15-second startup grace period, the backend requests bandwidth saver if the
buffer remains below three seconds and playback is waiting or downloads cannot keep
up for eight seconds. Pauses and brief stalls do not trigger it.

The app stops the current encoder and retunes with AI upscaling disabled, a 720p
maximum (480p if already configured), and the low encoder quality preset. This causes
a brief playback interruption and remains in effect until the next tune; global
server settings are unchanged. Resolution and quality reduction do not impose a
hard network bitrate cap. LTE and dropped-frame counts alone do not trigger fallback.
Direct/passthrough streams do not use this backend feedback mechanism.

To check on a device, play a transcoded live channel and throttle the connection
until it repeatedly runs out of buffer. Check for the app's “Retuning without
upscaling” log and the replacement FFmpeg process without a `dnn_processing` filter.
Also check that a short stall or manual pause does not cause a retune, and that tuning
again restores the configured quality.
