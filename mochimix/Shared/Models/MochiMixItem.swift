//
//  MochiMixItem.swift
//  Shared (used by both the mochimix app and the mochimix-widget extension)
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation

/// The single "display item" that both the app and the widget use to show
/// something the user recently played on Spotify.
///
/// This is NOT the raw Spotify API response -- it's a simplified, normalized
/// shape we compute ourselves (see ItemNormalizer later on), so the UI code
/// never has to know or care about Spotify's JSON structure. It could
/// represent a playlist, an album, an artist, or (as a last-resort fallback)
/// a single track.
struct MochiMixItem: Codable, Identifiable, Hashable {
    /// The Spotify URI of the underlying item, e.g. "spotify:album:123".
    /// We use this real-world identifier (instead of a random UUID) as the
    /// `id` so that the same playlist/album/artist/track always compares
    /// equal to itself -- that's what lets us deduplicate items later.
    var id: String

    enum ItemType: String, Codable {
        case playlist, album, artist, track

        /// Artists render as a circle everywhere (app + widget); every
        /// other type (playlist/album/track fallback) is a rounded-corner
        /// square. Kept as one shared flag so all the artwork call sites
        /// (widget, Recent list, pin search, pinned slots) apply the same
        /// rule instead of each re-deriving it.
        var isCircularArtwork: Bool { self == .artist }
    }
    var type: ItemType

    /// e.g. a playlist name, an album title, an artist name, or a track title.
    var name: String

    /// Secondary text shown under `name`, e.g. an artist name under an
    /// album title. `nil` when there's nothing meaningful to show (for
    /// example, an artist item has no separate subtitle).
    var subtitle: String?

    /// Where to download this item's artwork from. `nil` if Spotify didn't
    /// return an image for it.
    var artworkURL: URL?

    /// Once we've downloaded `artworkURL` into the shared App Group
    /// container (see ImageCache), we remember the local filename here so
    /// the widget can load the image straight from disk instead of making
    /// its own network request (widgets should avoid networking).
    var localArtworkFileName: String?

    /// Where tapping this item should take the user: an open.spotify.com
    /// link. These work as Universal Links straight into the Spotify app
    /// when it's installed, and fall back to opening in a browser when it
    /// isn't -- which is why we prefer them over a raw "spotify:" URI.
    var spotifyURL: URL
}

extension MochiMixItem {
    /// Hardcoded sample data so the widget and app UI can be built and
    /// previewed before Spotify auth/fetching exists. Deliberately has no
    /// artwork URLs, so we also get to see the "missing artwork" fallback
    /// UI for free while developing.
    static let mockItems: [MochiMixItem] = [
        MochiMixItem(
            id: "spotify:playlist:mock1",
            type: .playlist,
            name: "Late Night Drive",
            subtitle: nil,
            artworkURL: nil,
            localArtworkFileName: nil,
            spotifyURL: URL(string: "https://open.spotify.com/playlist/37i9dQZF1DX4o1oenSJRJd")!
        ),
        MochiMixItem(
            id: "spotify:album:mock2",
            type: .album,
            name: "Currents",
            subtitle: "Tame Impala",
            artworkURL: nil,
            localArtworkFileName: nil,
            spotifyURL: URL(string: "https://open.spotify.com/album/79dL7FLiJFOO0EoehUHQBv")!
        ),
        MochiMixItem(
            id: "spotify:artist:mock3",
            type: .artist,
            name: "Clairo",
            subtitle: nil,
            artworkURL: nil,
            localArtworkFileName: nil,
            spotifyURL: URL(string: "https://open.spotify.com/artist/3l0CmX0FuQjFxr8SK7Vqag")!
        ),
        MochiMixItem(
            id: "spotify:album:mock4",
            type: .album,
            name: "Blonde",
            subtitle: "Frank Ocean",
            artworkURL: nil,
            localArtworkFileName: nil,
            spotifyURL: URL(string: "https://open.spotify.com/album/3mH6qwIy9crq0I9YQbOuDf")!
        ),
        MochiMixItem(
            id: "spotify:track:mock5",
            type: .track,
            name: "Redbone",
            subtitle: "Childish Gambino",
            artworkURL: nil,
            localArtworkFileName: nil,
            spotifyURL: URL(string: "https://open.spotify.com/track/0wXuerDYiBnERgIpbb3JBR")!
        ),
    ]
}
