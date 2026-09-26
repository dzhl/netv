import AVKit
#if os(iOS)
import AVFAudio
#endif
import OSLog
import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    let selection: PlayerSelection

    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var quality: String?
    @State private var airPlayActive = false
    @State private var airPlayHost: String?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.netv",
        category: "Player"
    )

    var body: some View {
        ZStack {
            Color.black
            if let player {
                #if os(macOS)
                PlayerController(
                    player: player, volume: $model.playbackVolume,
                    compact: !model.isPlayerExpanded
                )
                #else
                PlayerController(player: player)
                #endif
            } else if let errorMessage {
                ContentUnavailableView(
                    "Unable to Play",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Tuning \(selection.channel.name)…")
                    .tint(.white)
            }

            #if os(iOS)
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selection.channel.name)
                            .font(.headline)
                        if let program = selection.program {
                            Text(program.title)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    Spacer()
                    if let quality {
                        Text(quality)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                    if let player {
                        AirPlayButton(player: player)
                            .frame(width: 36, height: 36)
                            .accessibilityLabel("AirPlay")
                    }
                }
                .padding()
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.75), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                Spacer()
            }
            .foregroundStyle(.white)
            #endif
        }
        #if os(macOS) || os(tvOS)
        #if os(macOS)
        .overlay(alignment: .top) {
            if airPlayActive, let airPlayHost {
                AirPlayHostWarning(host: airPlayHost)
                    .padding(12)
            }
        }
        #endif
        .overlay(alignment: .topLeading) {
            if let quality {
                Text(quality)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.65), in: Capsule())
                    #if os(tvOS)
                    .padding(model.isPlayerExpanded ? 48 : 18)
                    #else
                    .padding(12)
                    #endif
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: model.playbackVolume) { _, volume in
            player?.volume = Float(volume)
        }
        #endif
        #if os(tvOS)
        .onChange(of: model.playPauseRequest) { _, _ in
            if player?.timeControlStatus == .paused {
                player?.play()
            } else {
                player?.pause()
            }
        }
        #endif
        .task {
            await runPlayback()
        }
        .onDisappear {
            player?.pause()
        }
    }

    @MainActor
    private func runPlayback() async {
        var activeSessionID: String?
        defer {
            player?.pause()
            player = nil
            quality = nil
            airPlayActive = false
            if let sessionID = activeSessionID {
                Task { await model.stopPlayback(sessionID: sessionID) }
            }
        }
        do {
            #if os(iOS)
            try configureAudioSession()
            #endif
            while !Task.isCancelled {
                let bandwidthSaver = model.bandwidthSaver
                var configuration = try await model.playerConfiguration(for: selection)
                activeSessionID = configuration.transcodeSessionID
                try Task.checkCancellation()
                var options: [String: Any] = [:]
                if let cookie = configuration.cookieHeader {
                    options["AVURLAssetHTTPHeaderFieldsKey"] = ["Cookie": cookie]
                }
                let asset = AVURLAsset(url: configuration.url, options: options)
                guard try await asset.load(.isPlayable) else {
                    throw APIError.server("This channel's stream is not compatible with AVPlayer.")
                }
                try Task.checkCancellation()
                var item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 12
                var currentPlayer = AVPlayer(playerItem: item)
                currentPlayer.isMuted = false
                #if os(iOS)
                currentPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
                #endif
                airPlayHost = configuration.url.host.flatMap { isLoopback($0) ? $0 : nil }
                #if os(macOS) || os(tvOS)
                currentPlayer.volume = Float(model.playbackVolume)
                #else
                currentPlayer.volume = 1
                #endif
                player = currentPlayer
                currentPlayer.play()
                var sampler = PlaybackHealthSampler()
                var shouldRetune = false
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    quality = qualityLabel(for: item.presentationSize)
                    #if os(iOS) || os(macOS)
                    airPlayActive = currentPlayer.isExternalPlaybackActive
                    // The TV fetches segments itself, which keeps the session alive. Swapping
                    // players for a quality change would drop the AirPlay route.
                    if airPlayActive { continue }
                    #endif
                    guard let sessionID = activeSessionID else { continue }
                    // Pauses aren't stalls. Reporting healthy samples also resets the
                    // server's consecutive-poor-playback window and keeps it alive.
                    let health = sampler.sample(player: currentPlayer, item: item)
                    do {
                        let feedback = try await model.reportPlaybackHealth(
                            sessionID: sessionID, health: health
                        )
                        try Task.checkCancellation()
                        if let playlist = feedback.playlist,
                           let url = URL(string: playlist, relativeTo: configuration.url)?.absoluteURL,
                           url != configuration.url {
                            // Prepare locally while the current rendition keeps playing.
                            let replacement = try await prepareQualityPlayer(
                                url: url, options: options, currentItem: item
                            )
                            try Task.checkCancellation()
                            replacement.volume = currentPlayer.volume
                            replacement.isMuted = currentPlayer.isMuted
                            let wasPaused = currentPlayer.timeControlStatus == .paused
                            currentPlayer.pause()
                            currentPlayer = replacement
                            item = replacement.currentItem!
                            player = replacement
                            if !wasPaused { replacement.play() }
                            configuration = PlaybackConfiguration(
                                url: url, cookieHeader: configuration.cookieHeader,
                                transcodeSessionID: sessionID
                            )
                            sampler = PlaybackHealthSampler()
                            continue
                        }
                        if feedback.playlist == nil && feedback.bandwidthSaver != bandwidthSaver {
                            shouldRetune = true
                            break
                        }
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        // Older servers or transient telemetry failures must not stop playback.
                        logger.debug("Playback health unavailable: \(error.localizedDescription, privacy: .public)")
                    }
                }
                if shouldRetune {
                    logger.info("Switching playback quality")
                    currentPlayer.pause()
                    player = nil
                    quality = nil
                    if let sessionID = activeSessionID {
                        await model.stopPlayback(sessionID: sessionID)
                        activeSessionID = nil
                    }
                }
            }
        } catch {
            if !Task.isCancelled {
                logger.error("Playback failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func prepareQualityPlayer(
        url: URL, options: [String: Any], currentItem: AVPlayerItem
    ) async throws -> AVPlayer {
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        item.preferredForwardBufferDuration = 12
        let candidate = AVPlayer(playerItem: item)
        let deadline = Date().addingTimeInterval(8)
        while item.status == .unknown && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard item.status == .readyToPlay else {
            throw APIError.server("The new quality is not ready yet.")
        }
        // Both playlists expose dates derived from the same provider timestamps.
        // Refuse an upgrade without a shared timeline rather than jumping live.
        guard let date = currentItem.currentDate() else {
            throw APIError.server("Waiting for the shared playback timeline.")
        }
        let sought = await withCheckedContinuation { continuation in
            item.seek(to: date) { success in
                continuation.resume(returning: success)
            }
        }
        guard sought else {
            throw APIError.server("The new quality has not caught up yet.")
        }
        return candidate
    }

    #if os(iOS)
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
        let outputs = session.currentRoute.outputs
            .map { $0.portType.rawValue }
            .joined(separator: ", ")
        logger.info(
            "Audio session active: route=\(outputs.isEmpty ? "none" : outputs, privacy: .public) outputVolume=\(session.outputVolume)"
        )
    }
    #endif
}

#if os(macOS)
/// Native controls supply the system AirPlay button and volume slider. The slider
/// writes back to the app volume so it carries across channel and quality changes.
private struct PlayerController: NSViewRepresentable {
    let player: AVPlayer
    @Binding var volume: Double
    /// The guide preview uses the slim inline bar; fullscreen uses the floating panel.
    let compact: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = compact ? .inline : .floating
        view.videoGravity = .resizeAspect
        view.player = player
        context.coordinator.observe(player)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.volume = $volume
        let style: AVPlayerViewControlsStyle = compact ? .inline : .floating
        if view.controlsStyle != style {
            view.controlsStyle = style
        }
        if view.player !== player {
            view.player = player
            context.coordinator.observe(player)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(volume: $volume) }

    final class Coordinator {
        var volume: Binding<Double>
        private var observation: NSKeyValueObservation?

        init(volume: Binding<Double>) { self.volume = volume }

        func observe(_ player: AVPlayer) {
            observation = player.observe(\.volume, options: [.new]) { [weak self] player, _ in
                let value = Double(player.volume)
                DispatchQueue.main.async {
                    guard let self, abs(self.volume.wrappedValue - value) > 0.001 else { return }
                    self.volume.wrappedValue = value
                }
            }
        }
    }
}

private struct AirPlayHostWarning: View {
    let host: String

    var body: some View {
        Label(
            "The TV can't reach \(host). Sign in with this Mac's LAN address, such as http://192.168.1.10:8000.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
    }
}
#elseif os(iOS)
private struct AirPlayButton: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

private struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }
}
#else
private struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}

#endif

private func isLoopback(_ host: String) -> Bool {
    host == "localhost" || host == "::1" || host.hasPrefix("127.")
}

/// Classify on the larger of the frame height and the height a 16:9 frame of this width
/// would have: a letterboxed 1920x800 frame is a 1080p stream, not a 720p one.
private func qualityLabel(for size: CGSize) -> String? {
    guard size.width > 0, size.height > 0 else { return nil }
    switch max(size.height, size.width * 9 / 16) {
    case 2000...: return "4K"
    case 1300...: return "1440p"
    case 900...: return "1080p"
    case 650...: return "720p"
    case 520...: return "576p"
    case 400...: return "480p"
    default: return "SD"
    }
}

/// Use recent transfer deltas; a cumulative bitrate can hide a Wi-Fi-to-cellular slowdown.
private struct PlaybackHealthSampler {
    private var lastBytes: Int64 = 0
    private var lastTransferDuration: Double = 0
    private var lastEventStart: Date?

    mutating func sample(player: AVPlayer, item: AVPlayerItem) -> PlaybackHealth {
        let position = item.currentTime().seconds
        let buffer = item.loadedTimeRanges.reduce(0.0) { result, value in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            return start <= position && position <= end ? max(result, end - position) : result
        }
        var observed = 0.0
        var required = 0.0
        if let event = item.accessLog()?.events.last {
            if event.playbackStartDate != lastEventStart {
                lastBytes = 0
                lastTransferDuration = 0
                lastEventStart = event.playbackStartDate
            }
            let bytes = event.numberOfBytesTransferred - lastBytes
            let duration = event.transferDuration - lastTransferDuration
            if bytes > 0 && duration > 0 { observed = Double(bytes) * 8 / duration }
            lastBytes = event.numberOfBytesTransferred
            lastTransferDuration = event.transferDuration
            required = event.indicatedBitrate
            if required <= 0 {
                required = max(0, event.averageVideoBitrate) + max(0, event.averageAudioBitrate)
            }
        }
        let paused = player.timeControlStatus == .paused
        return PlaybackHealth(
            bufferSeconds: buffer.isFinite ? max(0, buffer) : 0,
            waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            observedBitrate: !paused && observed.isFinite ? max(0, observed) : 0,
            requiredBitrate: !paused && required.isFinite ? max(0, required) : 0
        )
    }
}
