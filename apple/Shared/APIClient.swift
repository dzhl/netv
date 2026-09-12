import Foundation
import OSLog

enum APIError: LocalizedError {
    case invalidServer
    case invalidResponse
    case authenticationFailed
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            "Enter a valid neTV server address."
        case .invalidResponse:
            "The server returned an unexpected response."
        case .authenticationFailed:
            "That username or password was not accepted."
        case .server(let message):
            message
        }
    }
}

struct PlaybackConfiguration {
    let url: URL
    let cookieHeader: String?
    let transcodeSessionID: String?
}

final class APIClient {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.netv",
        category: "API"
    )

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }

    func login(server: String, username: String, password: String) async throws -> URL {
        guard let baseURL = normalizedServerURL(server),
              let url = URL(string: "login", relativeTo: baseURL) else {
            throw APIError.invalidServer
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password)
        ]
        var components = URLComponents()
        components.queryItems = fields
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (_, response) = try await data(for: request, operation: "login")
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard http.url?.path != "/login", (200..<400).contains(http.statusCode) else {
            throw APIError.authenticationFailed
        }
        return baseURL
    }

    func validateSession(server: String) async throws -> Bool {
        guard let baseURL = normalizedServerURL(server),
              let url = URL(string: "api/user-prefs", relativeTo: baseURL) else {
            throw APIError.invalidServer
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, response) = try await data(for: request, operation: "session validation")
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        return http.statusCode == 200
    }

    func guide(server: String) async throws -> [ChannelRow] {
        guard let baseURL = normalizedServerURL(server) else {
            throw APIError.invalidServer
        }
        let preferences: UserPreferences = try await get("api/user-prefs", baseURL: baseURL)
        let categories = preferences.guideFilter?.joined(separator: ",") ?? ""
        var components = URLComponents(url: baseURL.appendingPathComponent("api/guide/rows"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "count", value: "500"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "cats", value: categories)
        ]
        guard let url = components?.url else { throw APIError.invalidServer }
        let response: GuideResponse = try await get(url: url)
        return response.rows
    }

    func playbackConfiguration(server: String, channelID: String, bandwidthSaver: Bool = false) async throws -> PlaybackConfiguration {
        guard let baseURL = normalizedServerURL(server),
              let playerPageURL = URL(string: "play/live/\(channelID)", relativeTo: baseURL) else {
            throw APIError.invalidServer
        }

        var request = URLRequest(url: playerPageURL)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await data(for: request, operation: "playback configuration")
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw APIError.authenticationFailed }
            throw APIError.server("Unable to resolve this channel (\(http.statusCode)).")
        }
        guard let html = String(data: data, encoding: .utf8),
              let rawURLString = playerConfigString("rawUrl", in: html),
              let rawURL = URL(string: rawURLString, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.server("The channel did not provide a playable stream.")
        }

        let transcodeMode = playerConfigString("transcodeMode", in: html) ?? "auto"
        if transcodeMode == "always" {
            return try await startTranscode(
                baseURL: baseURL,
                rawURL: rawURL,
                sourceID: playerConfigString("sourceId", in: html) ?? "",
                deinterlaceFallback: playerConfigBool("deinterlaceFallback", in: html) ?? true,
                bandwidthSaver: bandwidthSaver
            )
        }

        return PlaybackConfiguration(
            url: rawURL,
            cookieHeader: cookieHeader(for: rawURL),
            transcodeSessionID: nil
        )
    }

    func cookieHeader(for url: URL) -> String? {
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    func logout(server: String) async {
        guard let baseURL = normalizedServerURL(server),
              let url = URL(string: "logout", relativeTo: baseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        _ = try? await data(for: request, operation: "logout")
        HTTPCookieStorage.shared.cookies(for: baseURL)?.forEach {
            HTTPCookieStorage.shared.deleteCookie($0)
        }
    }

    func stopTranscode(server: String, sessionID: String) async {
        guard let baseURL = normalizedServerURL(server),
              let url = URL(string: "transcode/\(sessionID)?force=true", relativeTo: baseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await data(for: request, operation: "stop transcode")
    }

    func reportPlaybackHealth(server: String, sessionID: String, health: PlaybackHealth) async throws -> Bool {
        guard let baseURL = normalizedServerURL(server) else { throw APIError.invalidServer }
        let url = baseURL.appendingPathComponent("transcode/\(sessionID)/health")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(health)
        let (data, response) = try await data(for: request, operation: "playback health")
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError.invalidResponse
        }
        return try decoder.decode(PlaybackHealthResponse.self, from: data).bandwidthSaver
    }

    private func get<T: Decodable>(_ path: String, baseURL: URL) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.invalidServer
        }
        return try await get(url: url)
    }

    private func get<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await data(for: request, operation: "GET")
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw APIError.authenticationFailed }
            let detail = (try? decoder.decode(ServerError.self, from: data).detail)
            throw APIError.server(detail ?? "Server error \(http.statusCode)")
        }
        return try decoder.decode(T.self, from: data)
    }

    private func startTranscode(
        baseURL: URL,
        rawURL: URL,
        sourceID: String,
        deinterlaceFallback: Bool,
        bandwidthSaver: Bool
    ) async throws -> PlaybackConfiguration {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("transcode/start"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "url", value: rawURL.absoluteString),
            URLQueryItem(name: "content_type", value: "live"),
            URLQueryItem(name: "deinterlace_fallback", value: deinterlaceFallback ? "1" : "0"),
            URLQueryItem(name: "source_id", value: sourceID),
            URLQueryItem(name: "bandwidth_saver", value: bandwidthSaver ? "true" : "false")
        ]
        guard let url = components?.url else { throw APIError.invalidServer }
        let response: TranscodeResponse = try await get(url: url)
        guard let playlistURL = URL(string: response.playlist, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.invalidResponse
        }
        return PlaybackConfiguration(
            url: playlistURL,
            cookieHeader: cookieHeader(for: playlistURL),
            transcodeSessionID: response.sessionID
        )
    }

    private func data(
        for request: URLRequest,
        operation: String
    ) async throws -> (Data, URLResponse) {
        let endpoint = request.url.map(loggableEndpoint) ?? "<invalid URL>"
        let startedAt = Date()
        logger.info("\(operation, privacy: .public) started: \(endpoint, privacy: .public)")

        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = Date().timeIntervalSince(startedAt)
            if let http = response as? HTTPURLResponse {
                logger.info(
                    "\(operation, privacy: .public) finished: status=\(http.statusCode) bytes=\(data.count) duration=\(elapsed, format: .fixed(precision: 2))s endpoint=\(endpoint, privacy: .public)"
                )
            } else {
                logger.error(
                    "\(operation, privacy: .public) returned a non-HTTP response after \(elapsed, format: .fixed(precision: 2))s: \(endpoint, privacy: .public)"
                )
            }
            return (data, response)
        } catch {
            let elapsed = Date().timeIntervalSince(startedAt)
            logger.error(
                "\(operation, privacy: .public) failed after \(elapsed, format: .fixed(precision: 2))s: \(endpoint, privacy: .public), \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    private func loggableEndpoint(_ url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = url.path
        return components.string ?? "\(url.scheme ?? "unknown")://\(url.host ?? "unknown")\(url.path)"
    }

    private func playerConfigString(_ key: String, in html: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"\b\#(escapedKey)\s*:\s*("(?:\\.|[^"\\])*")"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: html,
                range: NSRange(html.startIndex..., in: html)
              ),
              let valueRange = Range(match.range(at: 1), in: html),
              let data = String(html[valueRange]).data(using: .utf8) else { return nil }
        return try? decoder.decode(String.self, from: data)
    }

    private func playerConfigBool(_ key: String, in html: String) -> Bool? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"\b\#(escapedKey)\s*:\s*(true|false)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: html,
                range: NSRange(html.startIndex..., in: html)
              ),
              let valueRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[valueRange]) == "true"
    }

    private func normalizedServerURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              components.host != nil else { return nil }
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        return components.url
    }
}

private struct ServerError: Decodable {
    let detail: String
}

private struct TranscodeResponse: Decodable {
    let sessionID: String
    let playlist: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case playlist
    }
}

struct PlaybackHealth: Encodable {
    let bufferSeconds: Double
    let waiting: Bool
    let observedBitrate: Double
    let requiredBitrate: Double

    enum CodingKeys: String, CodingKey {
        case bufferSeconds = "buffer_seconds"
        case waiting
        case observedBitrate = "observed_bitrate"
        case requiredBitrate = "required_bitrate"
    }
}

private struct PlaybackHealthResponse: Decodable {
    let bandwidthSaver: Bool

    enum CodingKeys: String, CodingKey {
        case bandwidthSaver = "bandwidth_saver"
    }
}
