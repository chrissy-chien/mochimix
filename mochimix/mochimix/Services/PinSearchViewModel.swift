//
//  PinSearchViewModel.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation
import Combine

/// Search state for the "pin something" flow (PinSearchView). Debouncing
/// is handled by the view via SwiftUI's `.task(id: query)` -- when `query`
/// changes, SwiftUI automatically cancels whatever `.task` was running for
/// the previous value and starts a new one, so a short `Task.sleep` at the
/// start of that task is all a debounce needs (no Combine or timers).
private struct SearchSortKey: Comparable {
    let matchRank: Int
    let name: String

    static func < (lhs: SearchSortKey, rhs: SearchSortKey) -> Bool {
        if lhs.matchRank != rhs.matchRank {
            return lhs.matchRank < rhs.matchRank
        }
        return lhs.name < rhs.name
    }
}

@MainActor
final class PinSearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var results: [MochiMixItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    /// Shown while `query` is empty, so the picker isn't just a blank
    /// screen before the user types anything.
    @Published private(set) var recommendations: [MochiMixItem] = []
    /// True only when there's no cache at all yet, so the picker needs a
    /// full-screen loading state.
    @Published private(set) var isLoadingRecommendations = false
    /// True while a background refresh is in flight -- distinct from
    /// `isLoadingRecommendations` because this can be true *while cached
    /// recommendations are already showing*, so the view can show a small
    /// "Loading more…" indicator under them instead of leaving the user
    /// with no sign that anything more is coming.
    @Published private(set) var isRefreshingRecommendations = false
    private var hasLoadedRecommendations = false

    /// How many recent items to show as recommendations.
    private static let recommendationCount = 10

    /// Shared across every `PinSearchViewModel` instance (a fresh one is
    /// created each time the pin picker sheet is presented), so reopening
    /// the picker repeatedly doesn't refire a background network refresh
    /// every time -- only the instant, no-network cached read does.
    private static var lastBackgroundRefresh: Date?
    private static let backgroundRefreshCooldown: TimeInterval = 30

    /// Defensive cap on the (trimmed) query length before it's sent to
    /// Spotify. Not confirmed to be a real limit for this endpoint (the
    /// actual "Invalid limit" bug turned out to be the `limit` parameter,
    /// not query length or encoding -- see SpotifyConfig.searchLimit), but
    /// there's no reason to ever send an extremely long query, so this
    /// stays as cheap insurance against a 400 from *some* over-length
    /// input we haven't seen yet.
    private static let maxQueryLength = 100
    private static let minimumLiveSearchLength = 2
    private static let searchCacheLimit = 40
    private static var searchResultCache: [String: [MochiMixItem]] = [:]
    private static var searchCacheOrder: [String] = []

    /// Runs one search for the current `query` and updates state. Only
    /// searches for playlists/albums/artists (never tracks) -- matches
    /// `SpotifyAPIClient.search`'s fixed type list, since only those three
    /// kinds of item can be pinned.
    func search() async {
        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            isLoading = false
            return
        }
        if trimmed.count > Self.maxQueryLength {
            trimmed = String(trimmed.prefix(Self.maxQueryLength))
        }

        guard normalizedSearchText(trimmed).count >= Self.minimumLiveSearchLength else {
            results = []
            errorMessage = nil
            isLoading = false
            return
        }

        let cacheKey = searchCacheKey(for: trimmed)
        if let cachedResults = Self.searchResultCache[cacheKey] {
            results = cachedResults
            errorMessage = nil
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            // `trimmed` is plain text here -- SpotifyAPIClient.search hands
            // it straight to URLQueryItem/URLComponents, which percent-
            // encodes it exactly once. Never pre-encode it here.
            let response = try await SpotifyAPIClient.shared.search(query: trimmed)
            guard !Task.isCancelled else { return }

            // Show regular Spotify search results as soon as they arrive.
            // Do not make the user wait for the saved-playlist library scan;
            // that can take much longer on-device and should only improve the
            // ordering after the initial results are already visible.
            let preliminaryRanked = rankedResults(for: trimmed, response: response, userPlaylists: [])
            results = preliminaryRanked
            isLoading = false

            let userPlaylists = (try? await SpotifyAPIClient.shared.fetchCurrentUserPlaylists()) ?? []
            guard !Task.isCancelled else { return }

            let fullyRanked = rankedResults(for: trimmed, response: response, userPlaylists: userPlaylists)
            cacheSearchResults(fullyRanked, for: cacheKey)
            results = fullyRanked
        } catch {
            // If a newer search superseded this one (the user kept typing),
            // SwiftUI already cancelled this task -- don't clobber the
            // newer search's in-progress/finished state with a stale error.
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func searchCacheKey(for query: String) -> String {
        normalizedSearchText(query)
    }

    private func cacheSearchResults(_ newResults: [MochiMixItem], for cacheKey: String) {
        guard !cacheKey.isEmpty else { return }

        Self.searchResultCache[cacheKey] = newResults
        Self.searchCacheOrder.removeAll { $0 == cacheKey }
        Self.searchCacheOrder.append(cacheKey)

        while Self.searchCacheOrder.count > Self.searchCacheLimit,
              let oldestKey = Self.searchCacheOrder.first {
            Self.searchCacheOrder.removeFirst()
            Self.searchResultCache.removeValue(forKey: oldestKey)
        }
    }

    private func rankedResults(for query: String, response: SpotifySearchResponse, userPlaylists: [SpotifyPlaylist]) -> [MochiMixItem] {
        let playlists = (response.playlists?.items ?? []).compactMap { $0 }
        let albums = (response.albums?.items ?? []).compactMap { $0 }
        let artists = (response.artists?.items ?? []).compactMap { $0 }

        let userPlaylistIDs = Set(userPlaylists.map(\.id))
        let directlyMatchingUserPlaylists = uniquePlaylists(userPlaylists + playlists.filter { userPlaylistIDs.contains($0.id) })
            .filter { directNameMatch($0.name, query: query) }
            .sorted { playlistSortKey($0.name, query: query) < playlistSortKey($1.name, query: query) }

        let unsavedPublicPlaylists = playlists
            .filter { !userPlaylistIDs.contains($0.id) }
            .sorted { playlistSortKey($0.name, query: query) < playlistSortKey($1.name, query: query) }

        let directlyMatchingAlbums = albums
            .filter { directNameMatch($0.name, query: query) }
            .sorted { albumSortKey($0.name, query: query) < albumSortKey($1.name, query: query) }

        let directlyMatchingArtists = artists
            .filter { directNameMatch($0.name, query: query) }
            .sorted { artistSortKey($0.name, query: query) < artistSortKey($1.name, query: query) }

        let bestAlbum = directlyMatchingAlbums.first
        let bestArtist = directlyMatchingArtists.first

        var ordered: [MochiMixItem] = []

        // The user's own/saved playlists are always the highest-priority
        // results when they directly match the query. This keeps personal
        // library matches above global Spotify artist/album/public-playlist
        // results.
        ordered += directlyMatchingUserPlaylists.map(MochiMixItemMapper.item(from:))

        // If the query directly names an album, show that album next, then
        // other albums by that album's primary artist alphabetically.
        if let bestAlbum {
            ordered.append(MochiMixItemMapper.item(from: bestAlbum))
            ordered += albumsBySamePrimaryArtist(as: bestAlbum, from: albums)
                .filter { $0.id != bestAlbum.id }
                .map(MochiMixItemMapper.item(from:))
        } else if let bestArtist {
            // If the query directly names an artist, show that artist next,
            // then that artist's albums alphabetically.
            ordered.append(MochiMixItemMapper.item(from: bestArtist))
            ordered += albumsByArtist(bestArtist, from: albums).map(MochiMixItemMapper.item(from:))
        }

        ordered += remainingItems(from: albums, query: query, alreadyUsed: ordered)
        ordered += remainingItems(from: artists, query: query, alreadyUsed: ordered)

        // Unsaved public playlists are deliberately last. They are often
        // noisy/global Spotify results compared with the user's own library,
        // artists, and albums.
        ordered += remainingItems(from: unsavedPublicPlaylists, query: query, alreadyUsed: ordered)

        return uniqueItems(ordered)
    }

    private func remainingItems(from albums: [SpotifyAlbum], query: String, alreadyUsed: [MochiMixItem]) -> [MochiMixItem] {
        let usedIDs = Set(alreadyUsed.map { "\($0.type.rawValue):\($0.id)" })

        return albums
            .sorted { albumSortKey($0.name, query: query) < albumSortKey($1.name, query: query) }
            .map(MochiMixItemMapper.item(from:))
            .filter { !usedIDs.contains("\($0.type.rawValue):\($0.id)") }
    }

    private func remainingItems(from artists: [SpotifyArtist], query: String, alreadyUsed: [MochiMixItem]) -> [MochiMixItem] {
        let usedIDs = Set(alreadyUsed.map { "\($0.type.rawValue):\($0.id)" })

        return artists
            .sorted { artistSortKey($0.name, query: query) < artistSortKey($1.name, query: query) }
            .map(MochiMixItemMapper.item(from:))
            .filter { !usedIDs.contains("\($0.type.rawValue):\($0.id)") }
    }

    private func remainingItems(from playlists: [SpotifyPlaylist], query: String, alreadyUsed: [MochiMixItem]) -> [MochiMixItem] {
        let usedIDs = Set(alreadyUsed.map { "\($0.type.rawValue):\($0.id)" })

        return playlists
            .sorted { playlistSortKey($0.name, query: query) < playlistSortKey($1.name, query: query) }
            .map(MochiMixItemMapper.item(from:))
            .filter { !usedIDs.contains("\($0.type.rawValue):\($0.id)") }
    }

    private func directNameMatch(_ name: String, query: String) -> Bool {
        let normalizedName = normalizedSearchText(name)
        let normalizedQuery = normalizedSearchText(query)
        guard !normalizedName.isEmpty, !normalizedQuery.isEmpty else { return false }

        if normalizedName == normalizedQuery { return true }
        if normalizedName.hasPrefix(normalizedQuery) { return true }
        if normalizedName.contains(normalizedQuery), normalizedQuery.count >= 2 { return true }
        if normalizedQuery.contains(normalizedName), normalizedName.count >= 3 { return true }

        return false
    }

    private func playlistSortKey(_ name: String, query: String) -> SearchSortKey {
        sortKey(for: name, query: query, fallbackName: name)
    }

    private func albumSortKey(_ name: String, query: String) -> SearchSortKey {
        sortKey(for: name, query: query, fallbackName: name)
    }

    private func artistSortKey(_ name: String, query: String) -> SearchSortKey {
        sortKey(for: name, query: query, fallbackName: name)
    }

    private func sortKey(for name: String, query: String, fallbackName: String) -> SearchSortKey {
        let normalizedName = normalizedSearchText(name)
        let normalizedQuery = normalizedSearchText(query)

        let matchRank: Int
        if normalizedName == normalizedQuery {
            matchRank = 0
        } else if normalizedName.hasPrefix(normalizedQuery) {
            matchRank = 1
        } else if normalizedName.contains(normalizedQuery) {
            matchRank = 2
        } else if normalizedQuery.contains(normalizedName) {
            matchRank = 3
        } else {
            matchRank = 4
        }

        return SearchSortKey(matchRank: matchRank, name: fallbackName.localizedLowercase)
    }

    private func normalizedSearchText(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }

    private func albumsByArtist(_ artist: SpotifyArtist, from albums: [SpotifyAlbum]) -> [SpotifyAlbum] {
        albums
            .filter { album in
                album.artists.contains { $0.id == artist.id || normalizedSearchText($0.name) == normalizedSearchText(artist.name) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func albumsBySamePrimaryArtist(as album: SpotifyAlbum, from albums: [SpotifyAlbum]) -> [SpotifyAlbum] {
        guard let primaryArtist = album.artists.first else { return [] }

        return albums
            .filter { candidate in
                candidate.artists.contains { $0.id == primaryArtist.id || normalizedSearchText($0.name) == normalizedSearchText(primaryArtist.name) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func uniquePlaylists(_ playlists: [SpotifyPlaylist]) -> [SpotifyPlaylist] {
        var seen: Set<String> = []
        var unique: [SpotifyPlaylist] = []

        for playlist in playlists where seen.insert(playlist.id).inserted {
            unique.append(playlist)
        }

        return unique
    }

    private func uniqueItems(_ items: [MochiMixItem]) -> [MochiMixItem] {
        var seen: Set<String> = []
        var unique: [MochiMixItem] = []

        for item in items {
            let key = "\(item.type.rawValue):\(item.id)"
            if seen.insert(key).inserted {
                unique.append(item)
            }
        }

        return unique
    }

    /// Loads the "recent items" recommendations shown while the search bar
    /// is empty, using the same shared normalization path as the Recent
    /// tab and the widget. Cache-first: the already-cached recent items
    /// SharedStore/the Recent tab uses are shown *immediately* (just a
    /// disk read, no network), and a fresh fetch only happens in the
    /// background -- so opening the picker never waits on a live Spotify
    /// fetch (which can involve many sequential requests) when a cache
    /// already exists. Only loads once per sheet presentation; the
    /// cross-instance cooldown above additionally prevents a background
    /// refetch on every rapid reopen.
    func loadRecommendationsIfNeeded() async {
        guard !hasLoadedRecommendations else { return }
        hasLoadedRecommendations = true

        let cached = SharedStore.shared.loadRecentItems()
        if !cached.isEmpty {
            recommendations = pinnableItems(from: cached)
        } else {
            isLoadingRecommendations = true
        }

        isLoadingRecommendations = false
        isRefreshingRecommendations = false
    }

    /// Only playlist/album/artist can be pinned -- tracks are only shown
    /// if there's truly nothing better to recommend.
    private func pinnableItems(from items: [MochiMixItem]) -> [MochiMixItem] {
        let pinnable = items.filter { $0.type != .track }
        return pinnable.isEmpty ? items : pinnable
    }

    func clear() {
        query = ""
        results = []
        errorMessage = nil
        isLoading = false
    }
}
