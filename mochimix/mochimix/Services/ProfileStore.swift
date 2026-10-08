//
//  ProfileStore.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation
import Combine

/// Caches the logged-in user's Spotify ID, display name + avatar URL, so
/// the header avatar and Settings screen's profile row has something to show immediately instead
/// of looking empty while a fresh `GET /v1/me` is in flight (or if it
/// fails). This is app-only, presentation-only data -- the widget never
/// needs it, so unlike SharedStore's data it just lives in the app's own
/// UserDefaults, not the App Group container.
@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published private(set) var displayName: String?
    @Published private(set) var avatarURL: URL?
    @Published private(set) var userID: String?

    /// The user's public Spotify profile page. An https link (rather than
    /// a `spotify:` URI) so it opens the Spotify app via universal link
    /// when installed, and falls back to the browser otherwise.
    var profileURL: URL? {
        guard let id = userID?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://open.spotify.com/user/\(id)")
    }

    private let cacheKey = "spotify_profile_cache"

    private struct Cached: Codable {
        let displayName: String?
        let avatarURLString: String?
        let userID: String?
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(Cached.self, from: data) {
            displayName = cached.displayName
            avatarURL = cached.avatarURLString.flatMap(URL.init)
            userID = cached.userID
        }
    }

    /// Fetches the current profile and updates the cache. Safe to call
    /// even if it fails -- the previously cached values (if any) just stay
    /// as they were, and the UI already falls back to "Spotify User" plus
    /// a placeholder avatar when both are nil.
    func refresh() async {
        guard let profile = try? await SpotifyAPIClient.shared.fetchCurrentUserProfile() else { return }
        displayName = profile.displayName
        avatarURL = (profile.images ?? []).first.flatMap { URL(string: $0.url) }
        userID = profile.id
        persist()
    }

    func clear() {
        displayName = nil
        avatarURL = nil
        userID = nil
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }

    private func persist() {
        let cached = Cached(displayName: displayName, avatarURLString: avatarURL?.absoluteString, userID: userID)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
