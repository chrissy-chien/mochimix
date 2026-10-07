//
//  LastFMAPIClient.swift
//  mochimix
//

import Foundation

/// Talks to Last.fm's public Web API (https://www.last.fm/api) -- used
/// only to resolve genre tags for an artist by name, since Spotify's own
/// `genres` field on artist objects has been unreliable/empty since
/// around March 2025 (a widely-reported issue, not specific to this app
/// -- see GenreStatsStore). No OAuth here, just a free personal API key.
final class LastFMAPIClient {
    static let shared = LastFMAPIClient()

    private init() {}

    private let decoder = JSONDecoder()

    enum APIError: LocalizedError {
        case invalidResponse
        case serverError(status: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Last.fm returned an unexpected response."
            case .serverError(let status, let body):
                #if DEBUG
                debugLog("Last.fm server error \(status): \(body)")
                #endif
                return "Last.fm couldn't complete that request right now (error \(status))."
            }
        }
    }

    /// artist.gettoptags -- returns an empty array (not an error) when
    /// Last.fm doesn't recognize the artist or has no tags for it, since
    /// that's a normal, frequent outcome for this lookup, not a failure.
    func fetchTopTags(artistName: String) async throws -> [LastFMTag] {
        var components = URLComponents(url: LastFMConfig.apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "method", value: "artist.gettoptags"),
            URLQueryItem(name: "artist", value: artistName),
            URLQueryItem(name: "api_key", value: LastFMConfig.apiKey),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "autocorrect", value: "1")
        ]
        guard let url = components.url else { return [] }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.serverError(status: http.statusCode, body: body)
        }

        let decoded = try decoder.decode(LastFMTopTagsResponse.self, from: data)
        return decoded.tags
    }
}
