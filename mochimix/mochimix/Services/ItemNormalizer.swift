//
//  ItemNormalizer.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation

/// The single shared path that turns raw Spotify play history into the
/// ordered, deduplicated list of normalized `MochiMixItem`s the app's
/// Recent tab, the pin search recommendations, and the widget's Recently
/// Played mode all use. There is deliberately only one implementation of
/// this logic -- everything else (WidgetDataProvider, PinSearchViewModel)
/// calls `fetchNormalizedRecentItems(desiredCount:)` rather than doing its
/// own fetching/normalizing.
///
/// For each play, we produce *exactly one* source item using this
/// priority:
///   1. `context.type == "playlist"` -> that playlist.
///   2. `context.type == "album"` -> that album.
///   3. `context.type == "artist"` -> that artist.
///   4. No useful context -> the track's own album.
///   5. Only if even that's unusable -> the track itself.
/// A play with a *known* context (playlist/artist) whose full-object fetch
/// fails is skipped entirely rather than misattributed to the track's
/// album -- see the note in `resolveItem` below for why.
enum ItemNormalizer {
    /// Safety cap on how many /recently-played pages we'll fetch while
    /// trying to reach `desiredCount` distinct items. Guards against
    /// unbounded API calls for a user with extremely repetitive listening
    /// (e.g. the same 2 playlists on loop for weeks).
    private static let maxPages = 6

    /// Fallback rate-limit cooldown when Spotify's 429 response doesn't
    /// include a `Retry-After` header. Not a guess at Spotify's real
    /// window -- just a short, bounded pause so a rate-limited run doesn't
    /// immediately retry the same still-limited context endpoint on the
    /// very next foreground/refresh, which was observed to keep the block
    /// from ever clearing.
    private static let defaultRateLimitCooldown: TimeInterval = 30

    /// One resolution outcome, computed unconditionally (it's cheap -- just
    /// a label) so debug logging never has to duplicate the actual
    /// resolution logic in `resolveItem`. Only consumed for logging.
    private enum ResolveOutcome {
        case usedContext(type: String)
        case rateLimited(type: String, retryAfter: TimeInterval?)
        case skippedDueToCooldown(type: String)
        case contextFetchFailed(type: String, error: String)
        case contextUnavailable(type: String)
        case fallbackAlbum
        case fallbackTrack

        func describe(selected item: MochiMixItem?) -> String {
            switch self {
            case .usedContext(let type):
                return "selected \(type) \"\(item?.name ?? "?")\" from context"
            case .rateLimited(let type, let retryAfter):
                return "DEGRADED -- Spotify returned 429 fetching \(type) context (retryAfter=\(retryAfter.map { "\($0)" } ?? "none")); selected \"\(item?.name ?? "?")\" as a fallback"
            case .skippedDueToCooldown(let type):
                return "DEGRADED -- existing rate-limit cooldown active; did not fetch \(type) context, selected \"\(item?.name ?? "?")\" as a fallback"
            case .contextFetchFailed(let type, let error):
                return "SKIPPED -- context type \(type) but fetching its full object failed: \(error)"
            case .contextUnavailable(let type):
                return "selected \"\(item?.name ?? "?")\" (fallback -- Spotify doesn't let this app read that \(type), e.g. a Spotify-generated mix)"
            case .fallbackAlbum:
                return "selected album \"\(item?.name ?? "?")\" (fallback -- no useful context)"
            case .fallbackTrack:
                return "selected track \"\(item?.name ?? "?")\" (last-resort fallback -- album also unusable)"
            }
        }
    }

    /// Fetches recently-played history (paging further back as needed) and
    /// returns up to `desiredCount` distinct normalized source items,
    /// ordered by most recent occurrence, alongside whether this run hit a
    /// 429 while resolving context objects. Paging stops once
    /// `desiredCount` distinct items are found, Spotify has no older
    /// history left, or `maxPages` is reached.
    ///
    /// `wasRateLimited` matters to callers because an empty `items` array
    /// means two very different things depending on it: `false` means
    /// Spotify genuinely has nothing to show (a fresh/empty account is
    /// fine to cache as empty); `true` means this run failed to resolve
    /// items it otherwise would have, and must NOT be treated the same as
    /// a trustworthy empty result (see WidgetDataProvider.refresh()).
    static func fetchNormalizedRecentItems(desiredCount: Int) async throws -> (items: [MochiMixItem], wasRateLimited: Bool) {
        var results: [MochiMixItem] = []
        var seenKeys: Set<String> = []
        var before: String?

        // Circuit breaker for this call: if a context fetch comes back
        // rate-limited (429), there's no point attempting dozens more in
        // the same normalization pass -- they'll almost certainly all fail
        // too, and each failed attempt still costs a full network round-trip.
        //
        // It's also seeded from an active persisted cooldown (below). That
        // used to be avoided because skipping bypassed the cache too and
        // dropped items; now a skipped context still resolves from
        // ContextCache, and an uncached one degrades to the track's album.
        var shouldSkipContextFetches = false
        var didReceiveFreshRateLimit = false
        var observedRetryAfter: TimeInterval?

        if let cooldownUntil = SharedStore.shared.rateLimitedUntil, cooldownUntil <= Date() {
            SharedStore.shared.rateLimitedUntil = nil
            #if DEBUG
            debugLog("fetchNormalizedRecentItems: prior rate-limit cooldown expired before refresh; cleared stored cooldown")
            #endif
        } else if let cooldownUntil = SharedStore.shared.rateLimitedUntil {
            // Still penalized: don't call the rate-limited context endpoints
            // at all (that only risks prolonging the penalty). Lookups
            // already in ContextCache still resolve normally, and everything
            // else degrades to the track's album -- never a blank list.
            shouldSkipContextFetches = true
            #if DEBUG
            debugLog("fetchNormalizedRecentItems: rate-limit cooldown active until \(cooldownUntil) -- using cached contexts only, no context requests this run")
            #endif
        }

        #if DEBUG
        debugLog("=== fetchNormalizedRecentItems(desiredCount: \(desiredCount)) starting ===")
        #endif

        do {
            if let current = try await SpotifyAPIClient.shared.fetchCurrentlyPlaying(),
               current.currentlyPlayingType == nil || current.currentlyPlayingType == "track" {
                let (item, outcome) = await resolveCurrentlyPlayingItem(current, skipContextFetch: shouldSkipContextFetches)
                if case .rateLimited(_, let retryAfter) = outcome {
                    shouldSkipContextFetches = true
                    didReceiveFreshRateLimit = true
                    observedRetryAfter = observedRetryAfter ?? retryAfter
                }

                #if DEBUG
                debugLog("currently-playing: type=\(current.currentlyPlayingType ?? "nil") context=\(current.context?.type ?? "none") contextURI=\(current.context?.uri ?? "none") -> \(outcome.describe(selected: item))")
                #endif

                if let item {
                    let key = dedupeKey(for: item)
                    if !seenKeys.contains(key) {
                        seenKeys.insert(key)
                        results.append(item)
                    } else {
                        #if DEBUG
                        debugLog("  skipped currently-playing item: duplicate of an already-selected item (key=\(key))")
                        #endif
                    }
                }
            }
        } catch {
            // Currently-playing is a freshness boost only. If it fails, keep
            // recently-played working rather than failing the whole refresh.
            #if DEBUG
            debugLog("fetchNormalizedRecentItems: currently-playing check failed, continuing with recently-played only: \(error)")
            #endif
        }

        for page in 0..<maxPages {
            if results.count >= desiredCount { break }
            if results.count >= desiredCount { break }

            let response = try await SpotifyAPIClient.shared.fetchRecentlyPlayed(before: before)
            #if DEBUG
            debugLog("page \(page): fetched \(response.items.count) raw history entries (before=\(before ?? "nil"))")
            #endif
            if response.items.isEmpty { break }

            for entry in response.items {
                if results.count >= desiredCount { break }

                let (item, outcome) = await resolveItem(for: entry, skipContextFetch: shouldSkipContextFetches)
                if case .rateLimited(_, let retryAfter) = outcome {
                    shouldSkipContextFetches = true
                    didReceiveFreshRateLimit = true
                    observedRetryAfter = observedRetryAfter ?? retryAfter
                }

                #if DEBUG
                debugLog("""
                    entry: track="\(entry.track.name)" album="\(entry.track.album.name)" \
                    context=\(entry.context?.type ?? "none") contextURI=\(entry.context?.uri ?? "none") \
                    -> \(outcome.describe(selected: item))
                    """)
                #endif

                guard let item else { continue }

                let key = dedupeKey(for: item)
                guard !seenKeys.contains(key) else {
                    #if DEBUG
                    debugLog("  skipped: duplicate of an already-selected item (key=\(key))")
                    #endif
                    continue
                }
                seenKeys.insert(key)
                results.append(item)
            }

            guard let nextBefore = response.cursors?.before, !nextBefore.isEmpty else {
                #if DEBUG
                debugLog("no more history available (cursors.before missing/empty) -- stopping")
                #endif
                break
            }
            before = nextBefore
        }

        if didReceiveFreshRateLimit {
            let cooldownUntil = Date().addingTimeInterval(observedRetryAfter ?? defaultRateLimitCooldown)
            SharedStore.shared.rateLimitedUntil = cooldownUntil
            #if DEBUG
            debugLog("fetchNormalizedRecentItems: received a fresh Spotify 429 this run -- recorded cooldown until \(cooldownUntil)")
            #endif
        } else if let cooldownUntil = SharedStore.shared.rateLimitedUntil, cooldownUntil <= Date() {
            SharedStore.shared.rateLimitedUntil = nil
            #if DEBUG
            debugLog("fetchNormalizedRecentItems: prior rate-limit cooldown expired after refresh; cleared stored cooldown")
            #endif
        }

        #if DEBUG
        debugLog("=== fetchNormalizedRecentItems finished with \(results.count) item(s): \(results.map { "\($0.type.rawValue):\($0.name)" }) (wasRateLimited=\(shouldSkipContextFetches || didReceiveFreshRateLimit), fresh429=\(didReceiveFreshRateLimit)) ===")
        #endif

        return (results, shouldSkipContextFetches || didReceiveFreshRateLimit)
    }

    /// Resolves the current playback response using the same source-item
    /// priority as recently-played history: playlist context first, then album,
    /// then artist, then the track's own album/track fallback. This lets a
    /// manual refresh surface the playlist/album/artist the user is listening
    /// to right now, before Spotify writes that play into history.
    private static func resolveCurrentlyPlayingItem(_ current: SpotifyCurrentlyPlayingResponse, skipContextFetch: Bool) async -> (MochiMixItem?, ResolveOutcome) {
        guard let track = current.item else {
            return (nil, .fallbackTrack)
        }

        if let context = current.context,
           let contextType = context.type,
           let hrefString = context.href,
           let href = URL(string: hrefString) {
            if skipContextFetch, ["playlist", "album", "artist"].contains(contextType) {
                if let cached = cachedContextItem(type: contextType, key: hrefString) {
                    return (cached, .usedContext(type: contextType))
                }
                return (degradedFallbackItem(for: track), .skippedDueToCooldown(type: contextType))
            }

            switch contextType {
            case "playlist":
                do {
                    let playlist = try await SpotifyAPIClient.shared.fetchPlaylist(at: href)
                    return (MochiMixItemMapper.item(from: playlist), .usedContext(type: "playlist"))
                } catch {
                    return outcome(for: error, track: track, contextType: "playlist")
                }
            case "album":
                do {
                    let album = try await SpotifyAPIClient.shared.fetchAlbum(at: href)
                    return (MochiMixItemMapper.item(from: album), .usedContext(type: "album"))
                } catch {
                    return outcome(for: error, track: track, contextType: "album")
                }
            case "artist":
                do {
                    let artist = try await SpotifyAPIClient.shared.fetchArtist(at: href)
                    return (MochiMixItemMapper.item(from: artist), .usedContext(type: "artist"))
                } catch {
                    return outcome(for: error, track: track, contextType: "artist")
                }
            default:
                break
            }
        }

        let album = track.album
        if !album.name.isEmpty {
            return (MochiMixItemMapper.item(from: album), .fallbackAlbum)
        }

        return (MochiMixItemMapper.item(from: track), .fallbackTrack)
    }

    /// A context already resolved on an earlier run (see ContextCache), so
    /// it can be shown even while context requests are being skipped.
    private static func cachedContextItem(type: String, key: String) -> MochiMixItem? {
        switch type {
        case "playlist": return ContextCache.shared.playlist(key).map(MochiMixItemMapper.item(from:))
        case "album": return ContextCache.shared.album(key).map(MochiMixItemMapper.item(from:))
        case "artist": return ContextCache.shared.artist(key).map(MochiMixItemMapper.item(from:))
        default: return nil
        }
    }

    /// Stable dedupe key: item type + Spotify id, so e.g. an album and a
    /// track that happen to share a raw id string can never collide.
    private static func dedupeKey(for item: MochiMixItem) -> String {
        "\(item.type.rawValue):\(item.id)"
    }

    /// Resolves a single play-history entry to its best display item (or
    /// `nil` if it shouldn't produce one at all), alongside a label
    /// describing what happened -- used only for the debug log above, so
    /// there is exactly one place the priority/fallback rules are coded.
    ///
    /// Returning `nil` on a failed playlist/album/artist fetch (rather
    /// than falling through to the track's album) is intentional for
    /// *genuine* failures (deleted/renamed playlist, decode error, etc.):
    /// if Spotify tells us this play came from a specific context, showing
    /// the track's own album instead when that context fetch fails would
    /// misattribute the source entirely. `album` context is fetched via
    /// `fetchAlbum(at:)` rather than assumed to equal the track's embedded
    /// album -- the debug log showed real cases where several tracks share
    /// one `context.uri` despite having different individual albums (e.g.
    /// a Spotify queue/mix session), so they must be resolved from the
    /// context itself to dedupe correctly.
    ///
    /// Rate-limited context fetches are the one deliberate exception (see
    /// `degradedFallbackItem`): a real observed `Retry-After` from Spotify
    /// on this app has been as long as ~17 hours, and misattribution for
    /// that whole window is a worse outcome than a completely blank
    /// Recently Played tab -- so those degrade to the track's own
    /// album/track instead of `nil`, clearly logged as degraded.
    private static func resolveItem(for entry: SpotifyPlayHistoryItem, skipContextFetch: Bool) async -> (MochiMixItem?, ResolveOutcome) {
        if let context = entry.context, let href = URL(string: context.href) {
            if skipContextFetch, ["playlist", "album", "artist"].contains(context.type) {
                if let cached = cachedContextItem(type: context.type, key: context.href) {
                    return (cached, .usedContext(type: context.type))
                }
                return (degradedFallbackItem(for: entry), .skippedDueToCooldown(type: context.type))
            }
            switch context.type {
            case "playlist":
                do {
                    let playlist = try await SpotifyAPIClient.shared.fetchPlaylist(at: href)
                    return (MochiMixItemMapper.item(from: playlist), .usedContext(type: "playlist"))
                } catch {
                    return outcome(for: error, entry: entry, contextType: "playlist")
                }
            case "album":
                do {
                    let album = try await SpotifyAPIClient.shared.fetchAlbum(at: href)
                    return (MochiMixItemMapper.item(from: album), .usedContext(type: "album"))
                } catch {
                    return outcome(for: error, entry: entry, contextType: "album")
                }
            case "artist":
                do {
                    let artist = try await SpotifyAPIClient.shared.fetchArtist(at: href)
                    return (MochiMixItemMapper.item(from: artist), .usedContext(type: "artist"))
                } catch {
                    return outcome(for: error, entry: entry, contextType: "artist")
                }
            default:
                break
            }
        }

        // No useful context -- fall back to the track's own album, unless
        // Spotify somehow gave us an album with no usable name (shouldn't
        // happen in practice, but keeps us from ever displaying a blank
        // item).
        let album = entry.track.album
        if !album.name.isEmpty {
            return (MochiMixItemMapper.item(from: album), .fallbackAlbum)
        }

        // Last resort: the track itself.
        return (MochiMixItemMapper.item(from: entry.track), .fallbackTrack)
    }

    /// Classifies a context-fetch failure by actual error type rather than
    /// string-matching the description -- a prior version checked
    /// `"\(error)".contains("429")`, which happened to work but was one
    /// error-message wording change away from silently breaking. A 429
    /// gets the degraded fallback item (see `degradedFallbackItem`); any
    /// other failure still returns `nil`, unchanged.
    private static func outcome(for error: Error, entry: SpotifyPlayHistoryItem, contextType: String) -> (MochiMixItem?, ResolveOutcome) {
        if let apiError = error as? SpotifyAPIClient.APIError, case .rateLimited(let retryAfter) = apiError {
            return (degradedFallbackItem(for: entry), .rateLimited(type: contextType, retryAfter: retryAfter))
        }
        if let apiError = error as? SpotifyAPIClient.APIError, case .unavailable = apiError {
            return (degradedFallbackItem(for: entry), .contextUnavailable(type: contextType))
        }
        return (nil, .contextFetchFailed(type: contextType, error: "\(error)"))
    }

    private static func outcome(for error: Error, track: SpotifyTrack, contextType: String) -> (MochiMixItem?, ResolveOutcome) {
        if let apiError = error as? SpotifyAPIClient.APIError, case .rateLimited(let retryAfter) = apiError {
            return (degradedFallbackItem(for: track), .rateLimited(type: contextType, retryAfter: retryAfter))
        }
        if let apiError = error as? SpotifyAPIClient.APIError, case .unavailable = apiError {
            return (degradedFallbackItem(for: track), .contextUnavailable(type: contextType))
        }
        return (nil, .contextFetchFailed(type: contextType, error: "\(error)"))
    }

    /// Used only when we already know (this run, via a fresh 429, or a
    /// persisted cooldown from an earlier run) that Spotify is
    /// rate-limiting context lookups. Trades slightly-less-precise
    /// attribution (the track's own album instead of the playlist/artist
    /// it was actually played from) for not leaving Recently Played
    /// completely blank for the entire rate-limit window.
    private static func degradedFallbackItem(for entry: SpotifyPlayHistoryItem) -> MochiMixItem? {
        let album = entry.track.album
        if !album.name.isEmpty {
            return MochiMixItemMapper.item(from: album)
        }
        return MochiMixItemMapper.item(from: entry.track)
    }

    private static func degradedFallbackItem(for track: SpotifyTrack) -> MochiMixItem? {
        let album = track.album
        if !album.name.isEmpty {
            return MochiMixItemMapper.item(from: album)
        }
        return MochiMixItemMapper.item(from: track)
    }
}
