# neTV for Apple

Native SwiftUI clients for iPhone, iPad, Apple TV, and Mac. All apps share the same authenticated neTV guide, channel artwork, program metadata, and AVPlayer playback while adapting navigation and layout to each platform.

## Open and run

1. Generate the project with `cd apple && xcodegen generate`.
2. Open `apple/neTV.xcodeproj`.
3. Select **neTV-iOS**, **neTV-tvOS**, or **neTV-macOS**, choose a destination, and run.
4. Sign in with the same neTV server address and account used by the web UI.

The development default is `http://localhost:8000`. HTTP transport is enabled because neTV commonly runs on a trusted local network; production deployments should use HTTPS.
