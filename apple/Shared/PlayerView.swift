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
    @State private var transcodeSessionID: String?
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
            logger.info("Tuning channel \(selection.channel.id, privacy: .public)")
            do {
                #if os(iOS)
                try configureAudioSession()
                #endif
                let configuration = try await model.playerConfiguration(for: selection)
                transcodeSessionID = configuration.transcodeSessionID
                logger.info(
                    "Playback configuration resolved: host=\(configuration.url.host ?? "unknown", privacy: .public) transcoding=\(configuration.transcodeSessionID != nil)"
                )
                var options: [String: Any] = [:]
                if let cookie = configuration.cookieHeader {
                    options["AVURLAssetHTTPHeaderFieldsKey"] = ["Cookie": cookie]
                }
                let asset = AVURLAsset(url: configuration.url, options: options)
                guard try await asset.load(.isPlayable) else {
                    throw APIError.server("This channel's stream is not compatible with AVPlayer.")
                }
                if let audioTracks = try? await asset.loadTracks(withMediaType: .audio) {
                    logger.info("Stream audio tracks discovered: \(audioTracks.count)")
                }
                let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player.isMuted = false
                player.volume = 1
                self.player = player
                player.play()
                logger.info("Playback started for channel \(selection.channel.id, privacy: .public)")
            } catch {
                logger.error(
                    "Playback failed for channel \(selection.channel.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                errorMessage = error.localizedDescription
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
            if let transcodeSessionID {
                Task { await model.stopPlayback(sessionID: transcodeSessionID) }
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
