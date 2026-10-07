//
//  GetGenreAPIClient.swift
//  mochimix
//

import Foundation

/// Talks to getGenre.com's API (https://api.getgenre.com) -- the primary
/// genre source for GenreStatsStore. Queried by **Spotify artist ID**
/// directly (getGenre's own `artist_id` is a Spotify ID -- confirmed by
/// a live test, Radiohead's getGenre response carried its real Spotify
/// ID), so there's no fuzzy name-matching risk the way there is with
/// Last.fm's by-name lookup.
final class GetGenreAPIClient {
    static let shared = GetGenreAPIClient()

    private init() {}

    private let decoder = JSONDecoder()

    enum APIError: LocalizedError {
        case invalidResponse
        case rateLimited
        case serverError(status: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "getGenre returned an unexpected response."
            case .rateLimited:
                return "getGenre is rate-limiting this app right now."
            case .serverError(let status, let body):
                #if DEBUG
                debugLog("getGenre server error \(status): \(body)")
                #endif
                return "getGenre couldn't complete that request right now (error \(status))."
            }
        }
    }

    /// Resolves an artist's genres by Spotify artist ID. Returns
    /// `genres` directly regardless of whether `analysis.exhausted` is
    /// true -- live testing showed a "still analyzing" (202) response
    /// often already carries real, usable genres (e.g. a first-ever
    /// lookup went from nothing to `["funk", "funk rock"]` on a second
    /// call seconds later), so waiting for full exhaustion isn't worth
    /// the complexity of a poll loop. `genres` is already in "leading
    /// order of relevance" per getGenre's own docs, so callers can just
    /// take a prefix rather than re-sorting.
    func fetchGenres(spotifyArtistID: String) async throws -> [String] {
        var components = URLComponents(
            url: GetGenreConfig.baseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "artist_id", value: spotifyArtistID)]
        let response: GetGenreArtistSearchResponse = try await get(components.url!)
        return response.genres
    }

    // MARK: - Authenticated GET, with one retry after a forced re-login

    private func get<T: Decodable>(_ url: URL, isRetry: Bool = false) async throws -> T {
        let token = try await GetGenreAuthService.shared.validAccessToken()

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        if http.statusCode == 401 && !isRetry {
            _ = try await GetGenreAuthService.shared.forceLogin()
            return try await get(url, isRetry: true)
        }

        if http.statusCode == 429 {
            throw APIError.rateLimited
        }

        // 200 (exhausted) and 202 (still analyzing, often still useful --
        // see fetchGenres) share the same response schema and are both
        // inside 200...299. 404 ("nothing found") also reuses the same
        // schema, just with `error` populated and `genres` empty.
        guard (200...299).contains(http.statusCode) || http.statusCode == 404 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.serverError(status: http.statusCode, body: body)
        }

        return try decoder.decode(T.self, from: data)
    }
}
