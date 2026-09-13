import Foundation
import OSLog

@MainActor
final class AppModel: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isCheckingSession = true
    @Published var isLoading = false
    @Published var channels: [ChannelRow] = []
    @Published var query = ""
    @Published var errorMessage: String?
    @Published var selection: PlayerSelection?
    @Published var isPlayerExpanded = false

    // Keep the downgrade across player recreation and channel changes for this app run.
    private(set) var bandwidthSaver = false

    @Published var server: String {
        didSet { UserDefaults.standard.set(server, forKey: "server") }
    }

    private let client = APIClient()
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
                || ($0.currentProgram?.title.localizedCaseInsensitiveContains(query) ?? false)
        }
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
            channels = try await client.guide(server: server)
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
        try await client.playbackConfiguration(server: server, channelID: selection.channel.id, bandwidthSaver: bandwidthSaver)
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
