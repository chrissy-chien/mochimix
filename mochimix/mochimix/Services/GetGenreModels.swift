//
//  GetGenreModels.swift
//  mochimix
//

import Foundation

/// POST /token response. `refresh_token` is only present when the token
/// request included `remember_me=true` -- GetGenreAuthService always
/// sets that, but the field stays optional to match the documented
/// schema (it's also absent for the `refresh_token` grant type, which
/// this app doesn't use).
struct GetGenreTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

/// GET /search response for an artist query. The same shape is reused
/// across HTTP 200 (fully analyzed), 202 (analysis still in progress --
/// but, per live testing, often already carries real, partial genres;
/// GenreStatsStore treats any non-empty `genres` as usable rather than
/// waiting for `analysis.exhausted`), and 404 (nothing found at all,
/// `error` populated, `genres` empty).
struct GetGenreArtistSearchResponse: Decodable {
    let error: String
    let artistID: String
    let artistName: String
    let analysis: GetGenreAnalysis
    let topGenres: [String]
    let genres: [String]
    let unvalidatedGenres: [String]

    private enum CodingKeys: String, CodingKey {
        case error
        case artistID = "artist_id"
        case artistName = "artist_name"
        case analysis
        case topGenres = "top_genres"
        case genres
        case unvalidatedGenres = "unvalidated_genres"
    }
}

struct GetGenreAnalysis: Decodable {
    let exhausted: Bool
    let level: Int
}
