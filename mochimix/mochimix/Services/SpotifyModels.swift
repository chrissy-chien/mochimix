//
//  SpotifyModels.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation

// These types mirror the raw JSON shapes returned by the Spotify Web API
// (https://developer.spotify.com/documentation/web-api). They exist purely
// so SpotifyAPIClient has something to decode into -- nothing outside of
// SpotifyAPIClient/ItemNormalizer should need to touch these directly. The
// rest of the app works with the simplified `MochiMixItem` instead (see
// Shared/Models/MochiMixItem.swift).
//
// SpotifyAPIClient decodes all of these using
// `.keyDecodingStrategy = .convertFromSnakeCase`, which is why the Swift
// property names below are camelCase even though Spotify's JSON uses
// snake_case (e.g. JSON "played_at" -> Swift `playedAt`).

struct SpotifyImage: Codable, Hashable {
    let url: String
    let width: Int?
    let height: Int?
}

struct SpotifyExternalURLs: Codable, Hashable {
    let spotify: String?
}

/// A lightweight reference to an artist, as embedded inside a track or
/// album object. Doesn't include images -- if we ever need an artist's
/// image, we have to fetch the full artist object separately.
struct SpotifyArtistRef: Codable, Hashable {
    let id: String
    let name: String
    let uri: String
    let externalUrls: SpotifyExternalURLs
}

struct SpotifyAlbum: Codable, Hashable {
    let id: String
    let name: String
    let uri: String
    // Optional: Spotify documents this field as nullable (not just
    // possibly-empty) for some objects. Decoding it as a plain
    // non-optional array would throw -- and silently fail the *entire*
    // object's decode -- the moment Spotify ever sends `"images": null`.
    let images: [SpotifyImage]?
    let externalUrls: SpotifyExternalURLs
    let artists: [SpotifyArtistRef]
}

struct SpotifyTrack: Codable, Hashable {
    let id: String
    let name: String
    let uri: String
    let externalUrls: SpotifyExternalURLs
    let album: SpotifyAlbum
    let artists: [SpotifyArtistRef]
}

/// The full artist object, fetched separately via GET /v1/artists/{id}
/// (or the `context.href` URL Spotify already gives us) when a recently
/// played track's context points at an artist.
struct SpotifyArtist: Codable, Hashable {
    let id: String
    let name: String
    let uri: String
    let images: [SpotifyImage]?
    let externalUrls: SpotifyExternalURLs
}

/// A playlist's owner -- who created/owns it, not who's currently viewing
/// it. Used as the playlist's subtitle everywhere a playlist is shown (see
/// MochiMixItemMapper).
struct SpotifyPlaylistOwner: Codable, Hashable {
    let id: String?
    let displayName: String?
}

/// The full playlist object, fetched the same way when a recently played
/// track's context points at a playlist.
///
/// `images` being nullable (not just possibly-empty) is the likely cause
/// of a real bug found via the debug log: across 703 logged playlist
/// context-fetch attempts, *every single one* failed, while artist fetches
/// (same auth/fetch code path, but Spotify's artist images are basically
/// never null) succeeded 100% of the time. That asymmetry points at a
/// decode failure specific to playlists rather than an auth/scope problem.
struct SpotifyPlaylist: Codable, Hashable {
    let id: String
    let name: String
    let uri: String
    let images: [SpotifyImage]?
    let externalUrls: SpotifyExternalURLs
    let owner: SpotifyPlaylistOwner?
}

/// The current logged-in user's public profile (GET /v1/me). `displayName`
/// and `images` are public-profile fields Spotify returns without needing
/// any extra scope beyond a valid access token.
struct SpotifyUserProfile: Codable, Hashable {
    let id: String
    let displayName: String?
    let images: [SpotifyImage]?
}

/// The "what was this track played as part of" hint on a play-history
/// entry -- e.g. the user pressed play on a specific playlist, album, or
/// artist page, and this track came from that. `href` is a ready-to-use API
/// URL for fetching the full object (no need to build one ourselves from
/// `uri`).
struct SpotifyContextRef: Codable, Hashable {
    let type: String
    let href: String
    let uri: String
    let externalUrls: SpotifyExternalURLs
}

struct SpotifyPlayHistoryItem: Codable, Hashable {
    let track: SpotifyTrack
    let playedAt: String
    let context: SpotifyContextRef?
}

/// Lets us page further back into history: `before` is a cursor value we
/// can pass as the next request's `before` query parameter to get older
/// plays than this batch. `nil`/empty means there's nothing older left.
struct SpotifyRecentlyPlayedCursors: Codable {
    let before: String?
}

struct SpotifyRecentlyPlayedResponse: Codable {
    let items: [SpotifyPlayHistoryItem]
    let cursors: SpotifyRecentlyPlayedCursors?
}

/// The current playback context returned by GET /v1/me/player/currently-playing.
/// It looks similar to `SpotifyContextRef`, but Spotify can return `null` for
/// some fields here, so this separate type keeps current-playback decoding from
/// failing when the context is incomplete.
struct SpotifyCurrentContextRef: Codable, Hashable {
    let type: String?
    let href: String?
    let uri: String?
    let externalUrls: SpotifyExternalURLs?
}

/// GET /v1/me/player/currently-playing. This is used to make manual refreshes
/// reflect the thing playing right now instead of waiting for Spotify to add the
/// track to recently-played history. `item` is optional because Spotify can
/// return no item when nothing is playing, and `currentlyPlayingType` lets the
/// normalizer ignore non-track playback safely.
struct SpotifyCurrentlyPlayingResponse: Codable, Hashable {
    let item: SpotifyTrack?
    let context: SpotifyCurrentContextRef?
    let isPlaying: Bool?
    let progressMs: Int?
    let currentlyPlayingType: String?
}

/// A Spotify "paging object" -- the wrapper shape most list endpoints
/// (including search) return results in. Items are decoded as optional:
/// Spotify's search results can contain `null` entries for
/// unavailable/removed items, and decoding straight to `[T]` would fail the
/// whole response if that ever happens. `compactMap` drops the nulls.
struct SpotifyPaging<T: Decodable>: Decodable {
    let items: [T?]
    let next: String?
}

/// GET /v1/search?type=playlist,album,artist response. Each field is
/// optional because Spotify omits a key entirely if that type wasn't
/// requested (we always request all three, but this is cheap insurance).
struct SpotifySearchResponse: Decodable {
    let playlists: SpotifyPaging<SpotifyPlaylist>?
    let albums: SpotifyPaging<SpotifyAlbum>?
    let artists: SpotifyPaging<SpotifyArtist>?
}
