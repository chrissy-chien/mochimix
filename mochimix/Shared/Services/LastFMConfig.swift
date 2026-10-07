//
//  LastFMConfig.swift
//  Shared (used by the mochimix app only; the widget extension has no
//  need for genre stats)
//

import Foundation

/// Last.fm is the fallback genre source (see LastFMAPIClient/GenreStatsStore)
/// -- used only when getGenre (the primary source) has nothing for an
/// artist.
///
/// Get a free API key at https://www.last.fm/api/account/create, then
/// set it in Shared/Services/Secrets.swift (see that file / the README).
nonisolated enum LastFMConfig {
    static let apiKey = Secrets.lastFMAPIKey
    static let apiBaseURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
}
