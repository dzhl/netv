// Compile with Shared/Models.swift and Shared/AppModel.swift, excluding APIClient.swift.
// The fake transport holds a start open to reproduce channel changes during startup.
import Foundation
import Combine

struct PlaybackConfiguration {
    let url: URL
    let cookieHeader: String? = nil
    let transcodeSessionID: String?
}
struct PlaybackHealth {}
struct PlaybackHealthResponse { let bandwidthSaver: Bool }
enum APIError: Error { case authenticationFailed, server(String) }

@MainActor
final class APIClient {
    static var starts = 0
    static var active: Set<String> = []
    static var overlapping = false
    static var failRelease = false
    static var saverResponse = false
    static var requestedSaver: [Bool] = []
    func playbackConfiguration(server: String, channelID: String, bandwidthSaver: Bool) async throws -> PlaybackConfiguration {
        Self.requestedSaver.append(bandwidthSaver)
        Self.starts += 1
        let id = "session-\(Self.starts)"
        Self.active.insert(id)
        Self.overlapping = Self.overlapping || Self.active.count > 1
        try await Task.sleep(for: .milliseconds(150))
        return PlaybackConfiguration(url: URL(string: "http://localhost/\(id)")!, transcodeSessionID: id)
    }
    func releaseTranscode(server: String, sessionID: String) async throws {
        if Self.failRelease { throw APIError.server("stop failed") }
        Self.active.remove(sessionID)
    }
    func stopTranscode(server: String, sessionID: String) async {
        try? await releaseTranscode(server: server, sessionID: sessionID)
    }
    func validateSession(server: String) async throws -> Bool { false }
    func login(server: String, username: String, password: String) async throws -> Bool { true }
    func logout(server: String) async {}
    func guide(server: String) async throws -> GuideResponse {
        try JSONDecoder().decode(
            GuideResponse.self,
            from: Data("{\"rows\":[],\"categories\":[],\"total\":0}".utf8)
        )
    }
    func reportPlaybackHealth(server: String, sessionID: String, health: PlaybackHealth) async throws -> PlaybackHealthResponse {
        PlaybackHealthResponse(bandwidthSaver: Self.saverResponse)
    }
}

@main
struct PlaybackStartChecks {
    @MainActor
    static func main() async throws {
        let model = AppModel()
        try checkGuideFiltering(model)
        func selection(_ id: String) throws -> PlayerSelection {
            let data = Data("{\"stream_id\":\"\(id)\",\"name\":\"Test\",\"icon\":\"\"}".utf8)
            return PlayerSelection(channel: try JSONDecoder().decode(Channel.self, from: data), program: nil)
        }
        let a = try selection("a")
        let b = try selection("b")
        let c = try selection("c")
        model.selection = a
        let first = Task { try await model.playerConfiguration(for: a) }
        while APIClient.starts == 0 { await Task.yield() }
        first.cancel()
        model.selection = b
        let second = Task { try await model.playerConfiguration(for: b) }
        await Task.yield()
        second.cancel()
        model.selection = c
        let third = Task { try await model.playerConfiguration(for: c) }
        _ = try? await first.value
        _ = try? await second.value
        let current = try await third.value
        precondition(!APIClient.overlapping, "Channel changes opened overlapping provider sessions")
        precondition(APIClient.active == [current.transcodeSessionID!], "Cancelled startup leaked a session")

        APIClient.failRelease = true
        let startsBeforeFailure = APIClient.starts
        for _ in 0..<2 {
            do {
                _ = try await model.playerConfiguration(for: c)
                preconditionFailure("Started playback despite failing to release the old session")
            } catch {}
        }
        precondition(APIClient.starts == startsBeforeFailure)
        APIClient.failRelease = false
        let recovered = try await model.playerConfiguration(for: c)
        precondition(!APIClient.overlapping)
        precondition(APIClient.active == [recovered.transcodeSessionID!])
        let sessionID = recovered.transcodeSessionID!
        APIClient.saverResponse = true
        _ = try await model.reportPlaybackHealth(sessionID: sessionID, health: PlaybackHealth())
        precondition(model.bandwidthSaver, "Server fallback must enable saver")
        APIClient.saverResponse = false
        _ = try await model.reportPlaybackHealth(sessionID: "obsolete", health: PlaybackHealth())
        precondition(model.bandwidthSaver, "Obsolete session feedback must not clear saver")
        _ = try await model.reportPlaybackHealth(sessionID: sessionID, health: PlaybackHealth())
        precondition(!model.bandwidthSaver, "Server recovery must clear saver")
        let restored = try await model.playerConfiguration(for: c)
        precondition(APIClient.requestedSaver.last == false, "Recovery must restore normal startup")
        APIClient.saverResponse = true
        _ = try await model.reportPlaybackHealth(sessionID: sessionID, health: PlaybackHealth())
        precondition(!model.bandwidthSaver, "Late fallback must not affect the new session")
        await model.stopPlayback(sessionID: restored.transcodeSessionID!)
        precondition(APIClient.active.isEmpty)
        print("Playback startup checks passed: cancellation, rapid tuning, failed release, recovery")
    }

    @MainActor
    private static func checkGuideFiltering(_ model: AppModel) throws {
        let data = Data("""
            [
              {"channel":{"stream_id":"news","name":"News","icon":"","category_ids":["1"]},
               "programs":[
                 {"title":"Headlines","desc":"","start":"00:00","end":"00:00","left_pct":0,"width_pct":50},
                 {"title":"Evening report","desc":"","start":"00:00","end":"00:00","left_pct":50,"width_pct":50}
               ]},
              {"channel":{"stream_id":"sports","name":"Sports","icon":"","category_ids":["2","1"]},"programs":[]},
              {"channel":{"stream_id":"other-news","name":"More News","icon":"","category_ids":["3"]},"programs":[]}
            ]
            """.utf8)
        model.channels = try JSONDecoder().decode([ChannelRow].self, from: data)
        model.guideCategories = try JSONDecoder().decode([GuideCategory].self, from: Data("""
            [
              {"category_id":"1","category_name":"News"},
              {"category_id":"2","category_name":"Sports"},
              {"category_id":"3","category_name":" news "}
            ]
            """.utf8))
        model.play(model.channels[0])
        let playing = model.selection
        defer {
            model.channels = []
            model.guideCategories = []
            model.query = ""
            model.selection = nil
        }
        precondition(model.filteredChannels(in: nil).count == 3)
        precondition(model.filteredChannels(in: "1").count == 2)
        precondition(model.filteredChannels(in: "2").map(\.id) == ["sports"])
        precondition(model.filteredChannels(in: "missing").isEmpty)
        precondition(model.guideCategoryGroups.count == 2)
        let newsGroup = model.guideCategoryGroups[0]
        precondition(model.filteredChannels(in: newsGroup.id).count == 3)
        model.query = "EVENING"
        precondition(model.filteredChannels(in: nil).map(\.id) == ["news"])
        precondition(model.filteredChannels(in: "2").isEmpty)
        precondition(model.filteredChannels(in: newsGroup.id).map(\.id) == ["news"])
        precondition(model.selection == playing, "Changing categories must not interrupt playback")
    }
}
