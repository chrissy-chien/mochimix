//
//  GetGenreConfig.swift
//  Shared (used by the mochimix app only; the widget extension has no
//  need for genre stats)
//

import Foundation

/// getGenre.com is the primary genre source (see GetGenreAuthService /
/// GetGenreAPIClient / GenreStatsStore) -- queried by exact Spotify
/// artist ID, with Last.fm as the fallback when it has nothing for an
/// artist.
///
/// Unlike Spotify's PKCE flow, this needs no browser/redirect: it's a
/// plain OAuth2 password grant against a getGenre.com account (email +
/// password in Secrets.swift).
nonisolated enum GetGenreConfig {
    static let baseURL = URL(string: "https://api.getgenre.com")!
    static let tokenURL = URL(string: "https://api.getgenre.com/token")!
    static let email = Secrets.getGenreEmail
    static let password = Secrets.getGenrePassword
}
