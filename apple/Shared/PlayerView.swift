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
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.netv",
        category: "Player"
    )

    var body: some View {
        ZStack {
            Color.black
            if let player {
                PlayerController(player: player)
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
        .overlay(alignment: .bottomLeading) {
            if player != nil {
                #if os(macOS)
                MacVolumeControl(volume: $model.playbackVolume)
                    .padding(12)
                #else
                TVVolumeControl(volume: $model.playbackVolume)
                    .padding(model.isPlayerExpanded ? 48 : 18)
                #endif
            }
        }
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
                        if feedback.playlist == nil && feedback.bandwidthSaver && !bandwidthSaver {
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
private struct PlayerController: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

private struct MacVolumeControl: View {
    @Binding var volume: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13))
                .frame(width: 16)
                .accessibilityHidden(true)
            Slider(value: $volume, in: 0...1)
                .labelsHidden()
                .controlSize(.small)
                .tint(.white)
                .frame(width: 90)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(volume * 100)) percent")
            Text("\(Int(volume * 100))%")
                .font(.caption2.monospacedDigit())
                .frame(width: 30, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }
}
#elseif os(iOS)
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

private struct TVVolumeControl: View {
    @Binding var volume: Double
    @FocusState private var focusedAdjustment: Adjustment?

    private enum Adjustment: Hashable {
        case down
        case up
    }

    var body: some View {
        HStack(spacing: 14) {
            volumeButton(.down, icon: "minus", label: "Decrease volume") {
                adjustVolume(by: -0.1)
            }
            Text("\(Int((volume * 100).rounded()))%")
                .font(.system(size: 22, weight: .medium).monospacedDigit())
                .frame(width: 62)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int((volume * 100).rounded())) percent")
            volumeButton(.up, icon: "plus", label: "Increase volume") {
                adjustVolume(by: 0.1)
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .focusSection()
    }

    private func adjustVolume(by delta: Double) {
        volume = min(1, max(0, ((volume + delta) * 100).rounded() / 100))
    }

    private func volumeButton(
        _ adjustment: Adjustment, icon: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .frame(width: 52, height: 44)
        }
        .buttonStyle(GuideButtonStyle(isFocused: focusedAdjustment == adjustment))
        .focused($focusedAdjustment, equals: adjustment)
        .accessibilityLabel(label)
    }
}
#endif

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
