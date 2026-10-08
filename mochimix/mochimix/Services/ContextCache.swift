//
//  ContextCache.swift
//  mochimix
//

import Foundation

/// Remembers resolved playlist/album/artist lookups across launches -- and,
/// just as importantly, lookups Spotify refused.
///
/// Why: the debug log showed ~500 requests for Spotify-generated mixes
/// (Daily Mix etc., ids starting `37i9dQZF1E`), every one a 404 -- Spotify
/// doesn't let development-mode apps read those playlists. Failures weren't
/// cached, so each refresh re-requested every one of them once per history
/// entry played from it, across up to 6 pages of history. Those bursts are
/// what triggered Spotify's hours-long, app-wide 429 penalties. Successes
/// were cached only in memory, so every launch repeated them too.
///
/// App-only (the widget never calls Spotify), so it lives in the app's own
/// Caches folder rather than the App Group container.
final class ContextCache {
    static let shared = ContextCache()

    /// How long a successful lookup is reused. Playlist names/covers do
    /// change occasionally, so this isn't forever.
    private static let successTTL: TimeInterval = 7 * 24 * 60 * 60
    /// How long a refused (404/403) lookup is skipped before trying again.
    private static let unavailableTTL: TimeInterval = 7 * 24 * 60 * 60

    private struct Stored: Codable {
        var playlists: [String: Entry<SpotifyPlaylist>] = [:]
        var albums: [String: Entry<SpotifyAlbum>] = [:]
        var artists: [String: Entry<SpotifyArtist>] = [:]
        /// Context URL -> when Spotify refused it.
        var unavailable: [String: Date] = [:]
    }

    private struct Entry<T: Codable>: Codable {
        let value: T
        let savedAt: Date
    }

    private let lock = NSLock()
    private var stored: Stored
    private let fileURL: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = caches.appendingPathComponent("spotify_context_cache.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
    }

    // MARK: - Lookups

    func playlist(_ key: String) -> SpotifyPlaylist? { fresh(\.playlists, key) }
    func album(_ key: String) -> SpotifyAlbum? { fresh(\.albums, key) }
    func artist(_ key: String) -> SpotifyArtist? { fresh(\.artists, key) }

    func isUnavailable(_ key: String) -> Bool {
        lock.withLock {
            guard let refusedAt = stored.unavailable[key] else { return false }
            return Date().timeIntervalSince(refusedAt) < Self.unavailableTTL
        }
    }

    // MARK: - Recording

    func store(playlist: SpotifyPlaylist, for key: String) { save(\.playlists, key, playlist) }
    func store(album: SpotifyAlbum, for key: String) { save(\.albums, key, album) }
    func store(artist: SpotifyArtist, for key: String) { save(\.artists, key, artist) }

    func markUnavailable(_ key: String) {
        lock.withLock { stored.unavailable[key] = Date() }
        persist()
    }

    func clear() {
        lock.withLock { stored = Stored() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Private

    private func fresh<T>(_ path: KeyPath<Stored, [String: Entry<T>]>, _ key: String) -> T? {
        lock.withLock {
            guard let entry = stored[keyPath: path][key],
                  Date().timeIntervalSince(entry.savedAt) < Self.successTTL else { return nil }
            return entry.value
        }
    }

    private func save<T>(_ path: WritableKeyPath<Stored, [String: Entry<T>]>, _ key: String, _ value: T) {
        lock.withLock {
            stored[keyPath: path][key] = Entry(value: value, savedAt: Date())
            stored.unavailable[key] = nil
        }
        persist()
    }

    private func persist() {
        let snapshot = lock.withLock { stored }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
