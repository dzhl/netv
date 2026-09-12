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
        }
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
            if let sessionID = activeSessionID {
                Task { await model.stopPlayback(sessionID: sessionID) }
            }
        }
        do {
            #if os(iOS)
            try configureAudioSession()
            #endif
            var bandwidthSaver = false
            while !Task.isCancelled {
                let configuration = try await model.playerConfiguration(
                    for: selection, bandwidthSaver: bandwidthSaver
                )
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
                let item = AVPlayerItem(asset: asset)
                let currentPlayer = AVPlayer(playerItem: item)
                currentPlayer.isMuted = false
                currentPlayer.volume = 1
                player = currentPlayer
                currentPlayer.play()
                var sampler = PlaybackHealthSampler()
                var shouldRetune = false
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    guard let sessionID = activeSessionID else { continue }
                    // Pauses aren't stalls. Reporting healthy samples also resets the
                    // server's consecutive-poor-playback window and keeps it alive.
                    let health = sampler.sample(player: currentPlayer, item: item)
                    do {
                        let reduceQuality = try await model.reportPlaybackHealth(
                            sessionID: sessionID, health: health
                        )
                        if reduceQuality && !bandwidthSaver {
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
                    logger.info("Retuning without upscaling after sustained playback pressure")
                    currentPlayer.pause()
                    player = nil
                    if let sessionID = activeSessionID {
                        await model.stopPlayback(sessionID: sessionID)
                        activeSessionID = nil
                    }
                    bandwidthSaver = true
                }
            }
        } catch {
            if !Task.isCancelled {
                logger.error("Playback failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
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
private struct PlayerController: View {
    let player: AVPlayer

    var body: some View {
        VideoPlayer(player: player)
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
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }
}
#endif

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
