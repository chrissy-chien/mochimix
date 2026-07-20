//
//  MochiMixItemMapper.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation

/// The single place that turns a raw Spotify object (playlist/album/
/// artist/track) into our normalized `MochiMixItem`. Both `ItemNormalizer`
/// (building items from recently-played history) and the pin search flow
/// (building items from /v1/search results) go through here, so rules like
/// "a playlist's subtitle is its owner's name" only need to be written once
/// and can't drift out of sync between the two call sites.
enum MochiMixItemMapper {
    static func item(from playlist: SpotifyPlaylist) -> MochiMixItem {
        MochiMixItem(
            id: playlist.uri,
            type: .playlist,
            name: playlist.name,
            subtitle: playlistSubtitle(for: playlist),
            artworkURL: (playlist.images ?? []).first.flatMap { URL(string: $0.url) },
            localArtworkFileName: nil,
            spotifyURL: url(from: playlist.externalUrls.spotify, orURI: playlist.uri)
        )
    }

    static func item(from artist: SpotifyArtist) -> MochiMixItem {
        MochiMixItem(
            id: artist.uri,
            type: .artist,
            name: artist.name,
            subtitle: "Artist",
            artworkURL: (artist.images ?? []).first.flatMap { URL(string: $0.url) },
            localArtworkFileName: nil,
            spotifyURL: url(from: artist.externalUrls.spotify, orURI: artist.uri)
        )
    }

    static func item(from album: SpotifyAlbum) -> MochiMixItem {
        MochiMixItem(
            id: album.uri,
            type: .album,
            name: album.name,
            subtitle: album.artists.first?.name,
            artworkURL: (album.images ?? []).first.flatMap { URL(string: $0.url) },
            localArtworkFileName: nil,
            spotifyURL: url(from: album.externalUrls.spotify, orURI: album.uri)
        )
    }

    static func item(from track: SpotifyTrack) -> MochiMixItem {
        MochiMixItem(
            id: track.uri,
            type: .track,
            name: track.name,
            subtitle: track.artists.first?.name,
            // Tracks don't carry their own artwork on Spotify -- artwork
            // always comes from the album they belong to.
            artworkURL: (track.album.images ?? []).first.flatMap { URL(string: $0.url) },
            localArtworkFileName: nil,
            spotifyURL: url(from: track.externalUrls.spotify, orURI: track.uri)
        )
    }

    /// Playlist subtitle rule: show who created/owns the playlist, falling
    /// back to a plain "Playlist" label when Spotify didn't give us an
    /// owner display name (e.g. a very old or algorithmic playlist).
    private static func playlistSubtitle(for playlist: SpotifyPlaylist) -> String {
        if let name = playlist.owner?.displayName, !name.isEmpty {
            return name
        }
        return "Playlist"
    }

    /// Prefers Spotify's own open.spotify.com link (works as a Universal
    /// Link into the Spotify app, with a browser fallback). If that's
    /// somehow missing, derives an equivalent open.spotify.com link from
    /// the item's own URI (e.g. "spotify:album:123" -> ".../album/123") so
    /// the tap target still goes somewhere useful.
    private static func url(from externalURLString: String?, orURI uri: String) -> URL {
        if let externalURLString, let url = URL(string: externalURLString) {
            return url
        }
        let parts = uri.split(separator: ":")
        guard parts.count == 3 else { return URL(string: "https://open.spotify.com")! }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")!
    }
}
