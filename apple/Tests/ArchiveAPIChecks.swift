// Compile with Shared/Models.swift and Shared/APIClient.swift.
import Foundation

private final class ArchiveTransport: URLProtocol {
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let url = request.url!
        let body: String
        if url.path.hasPrefix("/play/live/") {
            body = """
                rawUrl: "https://upstream.test/timeshift/user/pass/60/2026-09-28:10-00/1.ts",
                transcodeMode: "always", sourceId: "test", deinterlaceFallback: false,
                catchupStart: 1700000580.0, catchupSeek: 45.0
                """
        } else if url.path == "/transcode/start" {
            body = #"{"session_id":"archive","playlist":"/transcode/archive/stream.m3u8"}"#
        } else if url.path.hasPrefix("/transcode/progress/") {
            body = #"{"duration":120,"segment_count":60}"#
        } else {
            body = #"{"status":"stopped"}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct ArchiveAPIChecks {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArchiveTransport.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let playback = try await client.playbackConfiguration(
            server: "http://netv.test", channelID: "1", bandwidthSaver: true,
            catchupStart: 1_700_000_625
        )
        precondition(playback.archiveStart == 1_700_000_580)
        precondition(playback.archiveSeek == 45)
        precondition(playback.transcodeSessionID == "archive")
        let start = ArchiveTransport.requests.first { $0.url?.path == "/transcode/start" }!
        let query = URLComponents(url: start.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.contains(URLQueryItem(name: "content_type", value: "movie")))
        precondition(query.contains(URLQueryItem(name: "fast_start", value: "false")))
        precondition(query.contains(URLQueryItem(name: "bandwidth_saver", value: "false")))
        try await client.keepArchiveAlive(server: "http://netv.test", sessionID: "archive")
        precondition(ArchiveTransport.requests.last?.url?.path == "/transcode/progress/archive")
        try await client.releaseTranscode(server: "http://netv.test", sessionID: "archive")
        precondition(ArchiveTransport.requests.last?.httpMethod == "DELETE")
        precondition(ArchiveTransport.requests.last?.url?.query == "force=true")
        print("Archive API checks passed: exact position, VOD mode, heartbeat and forced release")
    }
}
