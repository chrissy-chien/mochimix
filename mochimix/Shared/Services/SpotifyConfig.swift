//
//  SpotifyConfig.swift
//  Shared (used by both the mochimix app and the mochimix-widget extension)
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation

/// Central place for the constants that tie this app to a specific Spotify
/// Developer Dashboard app registration and to this project's App Group.
///
/// The client ID below is NOT a secret -- with the PKCE flow this app uses
/// (see SpotifyAuthService), there is no client secret at all. PKCE was
/// designed for exactly this situation (a public client, like a mobile app,
/// that can't safely keep a secret), so it would be technically safe to
/// commit a real value here. It's still left as a placeholder rather than a
/// real ID, though: Spotify apps in Development Mode only let explicitly
/// allow-listed users log in at all, so a real ID checked into a public repo
/// wouldn't actually let anyone else log in anyway -- each person building
/// this needs to register their own Spotify app and drop their own client
/// ID in here (see README setup guide).
// `nonisolated` here because these are just plain constants -- there's no
// mutable state to protect, so there's no reason for the project-wide
// "default to MainActor" setting to force callers on other threads/actors
// (e.g. background fetch code) to hop onto the main actor just to read a
// URL or a number.
nonisolated enum SpotifyConfig {
    /// Replace with your own Spotify Developer Dashboard app's Client ID --
    /// see the README's "Spotify Developer Dashboard setup" section.
    static let clientID = "YOUR_SPOTIFY_CLIENT_ID"

    /// Must exactly match both:
    ///  1. The Redirect URI registered for this app in the Spotify
    ///     Developer Dashboard, and
    ///  2. The URL scheme declared in mochimix/Info.plist
    ///     (CFBundleURLSchemes -> "mochimix-login").
    static let redirectURI = URL(string: "mochimix-login://callback")!

    /// Space-separated OAuth scopes we request.
    ///
    /// `playlist-read-private` and `playlist-read-collaborative` are
    /// required to fetch full details (name/artwork/owner) for a private
    /// or collaborative playlist via GET /v1/playlists/{id} -- even one
    /// the user owns. Without these, that fetch 403s for any non-public
    /// playlist, which used to silently misattribute the play to the
    /// track's album (see ItemNormalizer). Requesting them here means
    /// existing logged-in users need to log in again once so Spotify can
    /// grant the added scope -- their old session won't have it.
    static let scope = "user-read-recently-played playlist-read-private playlist-read-collaborative user-read-currently-playing user-read-playback-state"

    static let authorizeURL = URL(string: "https://accounts.spotify.com/authorize")!
    static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    static let apiBaseURL = URL(string: "https://api.spotify.com/v1")!

    /// Must match the App Group entered in both targets' Signing &
    /// Capabilities tab (mochimix.entitlements and
    /// mochimix-widgetExtension.entitlements).
    static let appGroupIdentifier = "group.com.meowmeow.mochimix"

    /// How many history entries we ask Spotify for per recently-played
    /// fetch. We ask for more than 5 because several plays often resolve to
    /// the same source item (e.g. five tracks from the same playlist), and
    /// we need enough raw entries left to still find 5 *distinct* items.
    static let recentlyPlayedLimit = 20

    /// How many distinct, deduplicated items we want to end up with for
    /// display: 1 large "most recent" item + 4 small tiles.
    static let displayItemCount = 5

    /// Number of ordered pinned slots (1 top-eligible + 4 tile-eligible).
    static let pinnedSlotCount = 5

    /// How many results to ask Spotify for per search request when picking
    /// something to pin.
    ///
    /// Verified empirically against the real endpoint: Spotify's docs claim
    /// `limit` accepts 1-50, but with this app's client, `limit=15` (and
    /// higher) reliably returns `400 Invalid limit`, while `limit=10` (and
    /// lower) succeeds -- for every search type, combined or single. This
    /// was the actual cause of "Search unavailable" -- not double-encoding,
    /// query length, or the combined-vs-split-request question (all of
    /// those were also tested directly and ruled out). Do not raise this
    /// above 10 without re-verifying against a live request first.
    static let searchLimit = 10

    /// The widget's default tap target -- reuses the OAuth redirect's URL
    /// scheme (already registered in mochimix/Info.plist) but a distinct
    /// path, so tapping the widget's background just opens the app.
    /// SpotifyAuthService.handleRedirectIfNeeded only acts on this scheme
    /// when a login is actually pending, so receiving this URL when no
    /// login is in progress is already a harmless no-op there.
    static let openAppURL = URL(string: "mochimix-login://open")!

    /// A generic, item-independent Spotify link (not tied to anything
    /// specific) for the widget's play button -- opens Spotify itself via
    /// Universal Link, with a browser fallback, without needing an item.
    static let genericSpotifyURL = URL(string: "https://open.spotify.com/")!
}
