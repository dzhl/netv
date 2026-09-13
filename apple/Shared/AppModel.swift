import Combine
import Foundation
import OSLog

@MainActor
final class AppModel: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isCheckingSession = true
    @Published var isLoading = false
    @Published var channels: [ChannelRow] = []
    @Published var guideCategories: [GuideCategory] = []
    @Published var guideWindowStart = Date(
        timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600
    )
    @Published var query = ""
    @Published var errorMessage: String?
    @Published var selection: PlayerSelection?
    @Published var isPlayerExpanded = false
    #if os(macOS) || os(tvOS)
    @Published var playbackVolume: Double = 1
    #endif
    #if os(tvOS)
    @Published var playPauseRequest: UUID?
    #endif

    // Keep the downgrade across player recreation and channel changes for this app run.
    private(set) var bandwidthSaver = false

    @Published var server: String {
        didSet { UserDefaults.standard.set(server, forKey: "server") }
    }

    private let client = APIClient()
    private var playbackStartTask: Task<PlaybackConfiguration, Error>?
    private var playbackSessionToRelease: (server: String, id: String)?
    private var playbackStartGeneration = 0
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.netv",
        category: "App"
    )

    init() {
        server = UserDefaults.standard.string(forKey: "server") ?? "http://localhost:8000"
        Task { await restoreSession() }
    }

    var filteredChannels: [ChannelRow] {
        guard !query.isEmpty else { return channels }
        return channels.filter {
            $0.channel.name.localizedCaseInsensitiveContains(query)
                || $0.programs.contains { $0.title.localizedCaseInsensitiveContains(query) }
        }
    }

    func filteredChannels(in categoryID: String?) -> [ChannelRow] {
        guard let categoryID else { return filteredChannels }
        let categoryIDs = guideCategoryGroups.first(where: { $0.id == categoryID })?.categoryIDs
            ?? [categoryID]
        return filteredChannels.filter { !categoryIDs.isDisjoint(with: $0.channel.categoryIDs) }
    }

    var guideCategoryGroups: [GuideCategoryGroup] {
        GuideCategoryGroup.distinct(guideCategories)
    }

    func signIn(username: String, password: String) async {
        logger.info("Sign-in started")
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await client.login(server: server, username: username, password: password)
            isAuthenticated = true
            logger.info("Sign-in succeeded")
            await loadGuide()
        } catch {
            logger.error("Sign-in failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = connectionErrorMessage(for: error)
        }
    }

    func loadGuide() async {
        guard isAuthenticated else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let guide = try await client.guide(server: server)
            channels = guide.rows
            guideCategories = guide.categories
            guideWindowStart = Date(
                timeIntervalSince1970: guide.windowStartTimestamp
                    ?? floor(Date().timeIntervalSince1970 / 3600) * 3600
            )
            if selection == nil, let firstChannel = channels.first {
                play(firstChannel)
            }
            if channels.isEmpty {
                errorMessage = "No channels are selected. Choose guide categories in the neTV web settings."
            }
        } catch APIError.authenticationFailed {
            isAuthenticated = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func play(_ row: ChannelRow) {
        selection = PlayerSelection(channel: row.channel, program: row.currentProgram)
    }

    func playerConfiguration(for selection: PlayerSelection) async throws -> PlaybackConfiguration {
        let previous = playbackStartTask
        let requestServer = server
        playbackStartGeneration += 1
        let generation = playbackStartGeneration
        // Keep an in-flight start alive long enough to receive its session ID.
        // Cancelling its HTTP request doesn't cancel the server's encoder startup.
        let request = Task {
            if let previous { _ = try? await previous.value }
            if let previousSession = playbackSessionToRelease {
                try await client.releaseTranscode(server: previousSession.server, sessionID: previousSession.id)
                playbackSessionToRelease = nil
            }
            guard generation == playbackStartGeneration,
                  self.selection?.id == selection.id else {
                throw CancellationError()
            }
            let configuration = try await client.playbackConfiguration(
                server: requestServer, channelID: selection.channel.id,
                bandwidthSaver: bandwidthSaver
            )
            if let sessionID = configuration.transcodeSessionID {
                playbackSessionToRelease = (requestServer, sessionID)
            }
            return configuration
        }
        playbackStartTask = request
        let configuration = try await request.value
        if Task.isCancelled {
            if let sessionID = configuration.transcodeSessionID {
                await client.stopTranscode(server: requestServer, sessionID: sessionID)
            }
            throw CancellationError()
        }
        return configuration
    }

    func reportPlaybackHealth(sessionID: String, health: PlaybackHealth) async throws -> PlaybackHealthResponse {
        let response = try await client.reportPlaybackHealth(server: server, sessionID: sessionID, health: health)
        // Latch before the player awaits encoder cleanup, so switching channels
        // during a retune cannot start another high-quality stream.
        bandwidthSaver = bandwidthSaver || response.bandwidthSaver
        return response
    }

    func stopPlayback(sessionID: String) async {
        await client.stopTranscode(server: server, sessionID: sessionID)
    }

    func signOut() async {
        await client.logout(server: server)
        channels = []
        guideCategories = []
        isAuthenticated = false
    }

    private func restoreSession() async {
        logger.info("Saved-session check started")
        defer { isCheckingSession = false }
        do {
            isAuthenticated = try await client.validateSession(server: server)
            logger.info("Saved-session check finished: authenticated=\(self.isAuthenticated)")
            isCheckingSession = false
            if isAuthenticated {
                await loadGuide()
            }
        } catch {
            isAuthenticated = false
            errorMessage = connectionErrorMessage(for: error)
            logger.error("Saved-session check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func connectionErrorMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        switch urlError.code {
        case .timedOut:
            return "The server timed out. Check that the address is reachable from this device."
        case .cannotFindHost:
            return "The server name could not be resolved. Check the server address and DNS."
        case .cannotConnectToHost:
            return "The server refused the connection. Check that neTV is running and the port is correct."
        case .notConnectedToInternet:
            return "This device is not connected to the network."
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
            return "A secure connection could not be established. Check the server certificate."
        default:
            return urlError.localizedDescription
        }
    }
}
