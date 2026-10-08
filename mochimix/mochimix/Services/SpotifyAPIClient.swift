//
//  SpotifyAPIClient.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation

/// Talks to the Spotify Web API (https://api.spotify.com/v1). Every request
/// asks SpotifyAuthService for a currently-valid access token first (which
/// transparently refreshes it if it's expired), and retries a request
/// exactly once if Spotify unexpectedly responds 401 anyway.
final class SpotifyAPIClient {
    static let shared = SpotifyAPIClient()

    private init() {}

    /// Resolved (and refused) playlist/album/artist lookups, kept across
    /// launches -- see ContextCache for why this matters for rate limits.
    private let contextCache = ContextCache.shared
    private var currentUserPlaylistCache: (loadedAt: Date, playlists: [SpotifyPlaylist])?
    private var currentUserPlaylistFetchTask: Task<[SpotifyPlaylist], Error>?

    /// Spotify's JSON uses snake_case keys (e.g. "played_at"); this lets
    /// our Swift structs use normal camelCase property names (`playedAt`)
    /// without needing a CodingKeys enum for every single property.
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    enum APIError: LocalizedError {
        case invalidResponse
        case serverError(status: Int, body: String)
        case rateLimited(retryAfter: TimeInterval?)
        /// Spotify refused this object (404/403) -- e.g. Spotify-generated
        /// mixes, which development-mode apps can't read. Remembered in
        /// ContextCache so it isn't requested again.
        case unavailable
        case searchUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Spotify returned an unexpected response."
            case .serverError(let status, let body):
                // The raw body (which can be a full JSON error blob) is
                // useful for debugging but not something to show a user --
                // it goes to the debug log only. The UI gets a plain message.
                #if DEBUG
                debugLog("server error \(status): \(body)")
                #endif
                return "Spotify couldn't complete that request right now (error \(status)). Please try again."
            case .rateLimited:
                return "Spotify is rate-limiting this app right now. Please try again shortly."
            case .unavailable:
                return "Spotify doesn't make that item available to this app."
            case .searchUnavailable:
                return "Spotify search isn't available right now. Please try again in a moment."
            }
        }
    }


    /// GET /v1/me/player/recently-played. `before` pages further back into
    /// history than the most recent `limit` plays -- pass the previous
    /// response's `cursors.before` to get the next-older batch.
    func fetchRecentlyPlayed(limit: Int = SpotifyConfig.recentlyPlayedLimit, before: String? = nil) async throws -> SpotifyRecentlyPlayedResponse {
        var components = URLComponents(
            url: SpotifyConfig.apiBaseURL.appendingPathComponent("me/player/recently-played"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let before {
            queryItems.append(URLQueryItem(name: "before", value: before))
        }
        components.queryItems = queryItems
        do {
            let result: SpotifyRecentlyPlayedResponse = try await get(components.url!)
            #if DEBUG
            debugLog("fetchRecentlyPlayed: succeeded, \(result.items.count) raw item(s), before=\(before ?? "nil")")
            #endif
            return result
        } catch {
            #if DEBUG
            debugLog("fetchRecentlyPlayed: FAILED: \(error)")
            #endif
            throw error
        }
    }

    /// GET /v1/me/player/currently-playing. This lets a manual refresh see the
    /// thing playing right now instead of waiting for Spotify to write it into
    /// recently-played history. Spotify returns HTTP 204 when nothing is
    /// currently playing, so this method returns `nil` for that case.
    func fetchCurrentlyPlaying() async throws -> SpotifyCurrentlyPlayingResponse? {
        let url = SpotifyConfig.apiBaseURL.appendingPathComponent("me/player/currently-playing")
        do {
            let result: SpotifyCurrentlyPlayingResponse? = try await getOptional(url)
            #if DEBUG
            if let result {
                debugLog("fetchCurrentlyPlaying: succeeded, type=\(result.currentlyPlayingType ?? "nil"), isPlaying=\(result.isPlaying.map(String.init) ?? "nil"), hasContext=\(result.context != nil)")
            } else {
                debugLog("fetchCurrentlyPlaying: no currently-playing item")
            }
            #endif
            return result
        } catch {
            #if DEBUG
            debugLog("fetchCurrentlyPlaying: FAILED: \(error)")
            #endif
            throw error
        }
    }

    func fetchPlaylist(at href: URL) async throws -> SpotifyPlaylist {
        let key = href.absoluteString
        if let cached = contextCache.playlist(key) { return cached }
        if contextCache.isUnavailable(key) { throw APIError.unavailable }

        // The play-history context URL points at the full playlist endpoint.
        // Fetching it without `fields` pulls a large payload, including
        // playlist tracks, even though the UI only needs lightweight display
        // metadata. That is expensive and can help trigger Spotify 429s during
        // repeated refresh/debug sessions. Limit the response to the fields
        // needed by `MochiMixItemMapper.item(from:)`.
        let requestURL = lightweightPlaylistURL(from: href)
        let playlist: SpotifyPlaylist = try await getContext(requestURL, cacheKey: key)
        contextCache.store(playlist: playlist, for: key)
        return playlist
    }

    private func lightweightPlaylistURL(from href: URL) -> URL {
        var components = URLComponents(url: href, resolvingAgainstBaseURL: false)
        let fields = [
            "id",
            "name",
            "uri",
            "href",
            "external_urls",
            "images",
            "owner(id,display_name,uri,href,external_urls)"
        ].joined(separator: ",")

        var queryItems = components?.queryItems ?? []
        queryItems.removeAll { $0.name == "fields" }
        queryItems.append(URLQueryItem(name: "fields", value: fields))
        components?.queryItems = queryItems

        return components?.url ?? href
    }

    /// Used when a play-history entry's `context.type == "album"` --
    /// fetches the *context's own* album object, rather than assuming it's
    /// the same as the played track's embedded album (they can differ,
    /// e.g. Spotify queue/mix sessions that share one context across
    /// tracks from several different real albums).
    func fetchAlbum(at href: URL) async throws -> SpotifyAlbum {
        let key = href.absoluteString
        if let cached = contextCache.album(key) { return cached }
        if contextCache.isUnavailable(key) { throw APIError.unavailable }
        let album: SpotifyAlbum = try await getContext(href, cacheKey: key)
        contextCache.store(album: album, for: key)
        return album
    }

    func fetchArtist(at href: URL) async throws -> SpotifyArtist {
        let key = href.absoluteString
        if let cached = contextCache.artist(key) { return cached }
        if contextCache.isUnavailable(key) { throw APIError.unavailable }
        let artist: SpotifyArtist = try await getContext(href, cacheKey: key)
        contextCache.store(artist: artist, for: key)
        return artist
    }

    /// GET /v1/me/playlists -- used by the pin search flow to identify
    /// playlists the current user owns or has saved/followed. Spotify's
    /// generic playlist search heavily favors public/global results, so this
    /// endpoint lets the app put the user's own library matches first.
    func fetchCurrentUserPlaylists(force: Bool = false) async throws -> [SpotifyPlaylist] {
        if !force,
           let cached = currentUserPlaylistCache,
           Date().timeIntervalSince(cached.loadedAt) < 300 {
            return cached.playlists
        }

        if !force, let currentUserPlaylistFetchTask {
            return try await currentUserPlaylistFetchTask.value
        }

        let task = Task { () throws -> [SpotifyPlaylist] in
            var allPlaylists: [SpotifyPlaylist] = []
            var nextURL: URL? = currentUserPlaylistsURL(offset: 0)

            // Keep this intentionally small for search responsiveness. The
            // top of a user's playlist library is enough for ranking most
            // personal matches, and the result is cached for later searches.
            while let url = nextURL, allPlaylists.count < 100 {
                let page: SpotifyPaging<SpotifyPlaylist> = try await get(url)
                allPlaylists += page.items.compactMap { $0 }
                nextURL = page.next.flatMap(URL.init(string:))
            }

            return allPlaylists
        }

        currentUserPlaylistFetchTask = task

        do {
            let playlists = try await task.value
            currentUserPlaylistCache = (Date(), playlists)
            currentUserPlaylistFetchTask = nil
            return playlists
        } catch {
            currentUserPlaylistFetchTask = nil
            throw error
        }
    }

    private func currentUserPlaylistsURL(offset: Int) -> URL {
        var components = URLComponents(
            url: SpotifyConfig.apiBaseURL.appendingPathComponent("me/playlists"),
            resolvingAgainstBaseURL: false
        )!

        let fields = [
            "items(id,name,uri,external_urls,images,owner(id,display_name))",
            "next"
        ].joined(separator: ",")

        components.queryItems = [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "fields", value: fields)
        ]
        return components.url!
    }

    /// GET /v1/search -- used by the pin search flow. Deliberately never
    /// requests the "track" type: only playlists/albums/artists can be
    /// pinned.
    ///
    /// This issues 3 independent single-type requests **sequentially**
    /// (not concurrently, and not as one combined `type=playlist,album,
    /// artist` request). Two reasons:
    ///  1. A combined multi-type request has an intermittent server-side
    ///     Spotify bug that can reject an otherwise-valid `limit` with
    ///     "400 Invalid limit" -- verified by reproducing our exact URL
    ///     construction standalone and confirming it matches Spotify's
    ///     documented format byte-for-byte, so the combined `type`
    ///     parameter itself is the likely trigger.
    ///  2. Firing all 3 concurrently meant each independently called
    ///     `SpotifyAuthService.validAccessToken()` at once; if the token
    ///     needed refreshing right then, that could race (see
    ///     `refreshAccessTokenSingleFlight`) and plausibly fail more than
    ///     one of the three at the same time. Sequential requests remove
    ///     that risk entirely (now also covered by the single-flight guard
    ///     either way, but sequential is simplest to reason about).
    /// One type failing doesn't take down the other two -- `search(query:)`
    /// only throws if *all three* fail.
    func search(query: String, limit: Int = SpotifyConfig.searchLimit) async throws -> SpotifySearchResponse {
        let playlists = await fetchSearchType(query: query, typeParam: "playlist", limit: limit) { $0.playlists }
        let albums = await fetchSearchType(query: query, typeParam: "album", limit: limit) { $0.albums }
        let artists = await fetchSearchType(query: query, typeParam: "artist", limit: limit) { $0.artists }

        #if DEBUG
        debugLog("search(\"\(query)\") results: playlist=\(playlists != nil ? "ok(\(playlists?.items.count ?? 0))" : "FAILED") album=\(albums != nil ? "ok(\(albums?.items.count ?? 0))" : "FAILED") artist=\(artists != nil ? "ok(\(artists?.items.count ?? 0))" : "FAILED")")
        #endif

        guard playlists != nil || albums != nil || artists != nil else {
            throw APIError.searchUnavailable
        }

        return SpotifySearchResponse(playlists: playlists, albums: albums, artists: artists)
    }

    /// One single-type search request. Returns `nil` (rather than
    /// throwing) on failure so `search(query:)` can still return whatever
    /// types *did* succeed instead of failing the whole search over one
    /// type's issue.
    private func fetchSearchType<T>(
        query: String,
        typeParam: String,
        limit: Int,
        extract: (SpotifySearchResponse) -> T?
    ) async -> T? {
        var components = URLComponents(
            url: SpotifyConfig.apiBaseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: typeParam),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else { return nil }

        #if DEBUG
        // Logs the constructed request URL (no access token) so a failure
        // can be compared directly against Spotify's documented format.
        debugLog("[\(typeParam)] request: \(url.absoluteString)")
        #endif

        do {
            let response: SpotifySearchResponse = try await get(url)
            #if DEBUG
            debugLog("[\(typeParam)] success")
            #endif
            return extract(response)
        } catch {
            #if DEBUG
            if case APIError.serverError(let status, let body) = error {
                debugLog("[\(typeParam)] FAILED: status=\(status) body=\(body)")
            } else {
                debugLog("[\(typeParam)] FAILED: \(error)")
            }
            #endif
            return nil
        }
    }

    /// GET /v1/me -- the logged-in user's own profile, used for the
    /// Settings screen's profile row.
    func fetchCurrentUserProfile() async throws -> SpotifyUserProfile {
        try await get(SpotifyConfig.apiBaseURL.appendingPathComponent("me"))
    }

    /// GET /v1/me/top/artists -- Spotify's own affinity-ranked "top artists"
    /// for a given window, used for genre listening stats (GenreStatsStore).
    /// Each artist object already includes its `genres`, so no per-artist
    /// follow-up fetch is needed the way `fetchArtist` requires elsewhere.
    func fetchTopArtists(timeRange: String, limit: Int = 50) async throws -> [SpotifyArtist] {
        var components = URLComponents(
            url: SpotifyConfig.apiBaseURL.appendingPathComponent("me/top/artists"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "time_range", value: timeRange),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        do {
            let page: SpotifyPaging<SpotifyArtist> = try await get(components.url!)
            let artists = page.items.compactMap { $0 }
            #if DEBUG
            let withGenres = artists.filter { !($0.genres ?? []).isEmpty }.count
            debugLog("fetchTopArtists(\(timeRange)): succeeded, \(artists.count) artist(s), \(withGenres) with non-empty genres")
            #endif
            return artists
        } catch {
            #if DEBUG
            debugLog("fetchTopArtists(\(timeRange)): FAILED: \(error)")
            #endif
            throw error
        }
    }

    // MARK: - Generic authenticated GET, with one retry after a forced token refresh

    private func getOptional<T: Decodable>(_ url: URL, isRetry: Bool = false) async throws -> T? {
        let token = try await SpotifyAuthService.shared.validAccessToken()

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        #if DEBUG
        debugLog("Spotify GET \(url.path) -> HTTP \(http.statusCode)")
        #endif

        if http.statusCode == 204 {
            return nil
        }

        if http.statusCode == 401 && !isRetry {
            _ = try await SpotifyAuthService.shared.forceRefreshAccessToken()
            return try await getOptional(url, isRetry: true)
        }

        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw APIError.rateLimited(retryAfter: retryAfter)
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.serverError(status: http.statusCode, body: body)
        }

        if data.isEmpty {
            return nil
        }

        return try decoder.decode(T.self, from: data)
    }

    /// `get`, but a 404/403 is remembered as unavailable (so it's never
    /// re-requested every refresh) and reported as `.unavailable`.
    private func getContext<T: Decodable>(_ url: URL, cacheKey: String) async throws -> T {
        do {
            return try await get(url)
        } catch APIError.serverError(let status, _) where status == 404 || status == 403 {
            contextCache.markUnavailable(cacheKey)
            throw APIError.unavailable
        }
    }

    private func get<T: Decodable>(_ url: URL, isRetry: Bool = false) async throws -> T {
        let token = try await SpotifyAuthService.shared.validAccessToken()

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        #if DEBUG
        debugLog("Spotify GET \(url.path) -> HTTP \(http.statusCode)")
        #endif

        if http.statusCode == 401 && !isRetry {
            // Our cached token looked valid, but Spotify disagreed (e.g. it
            // was revoked early). Force one refresh and retry exactly once
            // -- if that still fails, something's genuinely wrong and we
            // should surface the error rather than loop forever.
            _ = try await SpotifyAuthService.shared.forceRefreshAccessToken()
            return try await get(url, isRetry: true)
        }

        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw APIError.rateLimited(retryAfter: retryAfter)
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.serverError(status: http.statusCode, body: body)
        }

        return try decoder.decode(T.self, from: data)
    }
}
