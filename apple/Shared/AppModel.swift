import Foundation

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

    @Published var server: String {
        didSet { UserDefaults.standard.set(server, forKey: "server") }
    }

    private let client = APIClient()

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
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await client.login(server: server, username: username, password: password)
            isAuthenticated = true
            await loadGuide()
        } catch {
            errorMessage = error.localizedDescription
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
        try await client.playbackConfiguration(server: server, channelID: selection.channel.id)
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
        isAuthenticated = await client.validateSession(server: server)
        isCheckingSession = false
        if isAuthenticated {
            await loadGuide()
        }
    }
}
