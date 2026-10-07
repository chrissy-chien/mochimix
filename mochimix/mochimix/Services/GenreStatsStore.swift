//
//  GenreStatsStore.swift
//  mochimix
//

import Foundation
import Combine

/// Caches a genre breakdown of the logged-in user's Spotify "top artists"
/// for each of Spotify's three affinity windows (GET /me/top/artists).
///
/// Genre tags themselves come from **getGenre.com** (primary) and
/// **Last.fm** (fallback), not Spotify: Spotify's own `genres` field on
/// artist objects has been unreliable/empty since around March 2025
/// (confirmed via this app's own debug log -- 50/50 top artists came
/// back with `genres: []` across all three time ranges -- and matches
/// widely-reported community issues, not anything specific to this app
/// or account). See `resolveGenres(for:)` for the two-source order.
///
/// App-only, presentation-only data -- the widget never needs it, so
/// (like ProfileStore) this lives in the app's own UserDefaults, not the
/// App Group container.
@MainActor
final class GenreStatsStore: ObservableObject {
    static let shared = GenreStatsStore()

    enum TimeRange: String, CaseIterable, Codable {
        case shortTerm = "short_term"
        case mediumTerm = "medium_term"
        case longTerm = "long_term"

        var label: String {
            switch self {
            case .shortTerm: return "4 Weeks"
            case .mediumTerm: return "6 Months"
            case .longTerm: return "1 Year"
            }
        }
    }

    struct GenreShare: Identifiable, Codable, Hashable {
        var id: String { genre }
        let genre: String
        let count: Int
        let fraction: Double
    }

    /// One major genre's share of overall listening -- see
    /// `majorGenreBreakdown(in:)` for how `fraction` is computed so
    /// these always sum to 1.0 across a full breakdown.
    struct MajorGenreShare: Identifiable, Hashable {
        var id: ParentGenre { parentGenre }
        let parentGenre: ParentGenre
        let fraction: Double
    }

    @Published private(set) var breakdowns: [TimeRange: [GenreShare]] = [:]

    // Retained so the Stats tab can expand a genre row into "top artists
    // for this genre" without a fresh network call -- already-ranked
    // (Spotify returns top artists in affinity order), so taking a
    // prefix after filtering by genre is enough, no re-sorting needed.
    @Published private(set) var topArtistsByRange: [TimeRange: [SpotifyArtist]] = [:]

    private let breakdownCacheKey = "spotify_genre_stats_cache"
    private let tagCacheKey = "lastfm_artist_tag_cache"

    // 1 hour: long enough that opening the Stats tab repeatedly doesn't
    // refire 3 Spotify requests every time, short enough to reflect a
    // user's listening changing without needing a manual refresh.
    private let breakdownCacheTTL: TimeInterval = 3600

    // Last.fm tags are free-form and community-voted, not pure genres
    // (eras, moods, "seen live", nationalities, etc. all show up) --
    // taking all of them would pull in a lot of noise. Last.fm already
    // sorts tags by weight descending, so the top few are the most
    // genre-relevant ones.
    private let tagsPerArtist = 5

    private struct CachedBreakdowns: Codable {
        var breakdowns: [TimeRange: [GenreShare]]
        var topArtistsByRange: [TimeRange: [SpotifyArtist]]
        var loadedAt: Date
    }

    private var loadedAt: Date?

    // Spotify artist ID -> resolved genre tags. No TTL -- an artist's
    // genre doesn't meaningfully change day to day, and this avoids
    // re-hitting Last.fm for the same largely-overlapping ~50 artists
    // on every refresh.
    private var artistGenreCache: [String: [String]] = [:]

    // The in-flight refresh, if any -- owned by the store itself, not by
    // whichever view's `.task` happened to trigger it. Resolving ~50+
    // artists sequentially against Last.fm can take a while, and without
    // this, SwiftUI cancels a view's `.task` the instant that view
    // disappears (e.g. switching away from the Stats tab mid-refresh),
    // which cooperatively cancels any in-flight URLSession request on
    // that Task and surfaces as a spurious NSURLErrorCancelled (-999) --
    // not an actual Spotify/Last.fm failure. A plain unstructured `Task`
    // created here has no parent-child relationship to the caller's own
    // Task, so it keeps running to completion regardless of what the
    // view that started it does afterward.
    private var refreshTask: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: breakdownCacheKey),
           let cached = try? JSONDecoder().decode(CachedBreakdowns.self, from: data) {
            breakdowns = cached.breakdowns
            topArtistsByRange = cached.topArtistsByRange
            loadedAt = cached.loadedAt
        }
        if let data = UserDefaults.standard.data(forKey: tagCacheKey),
           let cached = try? JSONDecoder().decode([String: [String]].self, from: data) {
            artistGenreCache = cached
        }
    }

    /// Refreshes all three time ranges. Safe to call even if some/all
    /// requests fail -- whatever previously cached breakdowns exist (if
    /// any) just stay as they were.
    ///
    /// If a refresh is already in flight (started by this call or an
    /// earlier one, from this view or a different one), this just awaits
    /// that same task rather than starting a duplicate.
    func refreshAll(force: Bool = false) async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < breakdownCacheTTL {
            return
        }

        let task = Task {
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        var artistsByRange: [TimeRange: [SpotifyArtist]] = [:]
        for range in TimeRange.allCases {
            do {
                let artists = try await SpotifyAPIClient.shared.fetchTopArtists(timeRange: range.rawValue)
                artistsByRange[range] = artists
            } catch {
                #if DEBUG
                debugLog("GenreStatsStore.refreshAll(\(range.rawValue)): FAILED to fetch top artists: \(error)")
                #endif
            }
        }

        guard !artistsByRange.isEmpty else { return }

        // Resolve genre tags for every distinct artist across all three
        // ranges once (sequentially -- getGenre showed no rate limiting
        // in testing, but there's no documented ceiling either, so this
        // stays conservative rather than firing requests concurrently)
        // rather than per range -- the same popular artists usually
        // appear in more than one time range.
        var distinctArtists: [String: SpotifyArtist] = [:]
        for artists in artistsByRange.values {
            for artist in artists {
                distinctArtists[artist.id] = artist
            }
        }

        for (id, artist) in distinctArtists {
            guard artistGenreCache[id] == nil else { continue }
            if let genres = await resolveGenres(for: artist) {
                artistGenreCache[id] = genres
            }
        }
        persistTagCache()

        for (range, artists) in artistsByRange {
            let shares = Self.genreShares(for: artists, using: artistGenreCache)
            #if DEBUG
            debugLog("GenreStatsStore.refreshAll(\(range.rawValue)): \(artists.count) artist(s) -> \(shares.count) genre(s)")
            #endif
            breakdowns[range] = shares
        }
        topArtistsByRange = artistsByRange
        loadedAt = Date()
        persistBreakdowns()
    }

    func clear() {
        breakdowns = [:]
        topArtistsByRange = [:]
        loadedAt = nil
        artistGenreCache = [:]
        UserDefaults.standard.removeObject(forKey: breakdownCacheKey)
        UserDefaults.standard.removeObject(forKey: tagCacheKey)
    }

    /// The top artists (already affinity-ranked by Spotify, so no
    /// re-sorting needed) that resolved to `genre` in `range`, capped at
    /// 5 -- backs the Stats tab's "tap a genre to see its artists" row.
    func topArtists(forGenre genre: String, in range: TimeRange, limit: Int = 5) -> [SpotifyArtist] {
        guard let artists = topArtistsByRange[range] else { return [] }
        return Array(artists.filter { artistGenreCache[$0.id]?.contains(genre) == true }.prefix(limit))
    }

    /// Each major genre's share of overall listening, guaranteed to sum
    /// to 1.0 across the full result (including `.other`). An artist
    /// tagged with genres spanning more than one family (e.g. "indie
    /// rock" + "electronic" -> Indie and Electronic both) splits its
    /// weight evenly across however many distinct families it touches,
    /// rather than being double-counted in each -- that's what keeps the
    /// total exactly 1.0 regardless of how much overlap there is,
    /// without throwing away the fact that the artist genuinely spans
    /// more than one family.
    ///
    /// Always returns one entry per `ParentGenre.allCases`, even families
    /// with no representation this period (`fraction: 0`) -- the Stats
    /// tab still lists every major genre, just as a non-expandable 0%
    /// row, rather than omitting it entirely.
    func majorGenreBreakdown(in range: TimeRange) -> [MajorGenreShare] {
        guard let artists = topArtistsByRange[range] else {
            return ParentGenre.allCases.map { MajorGenreShare(parentGenre: $0, fraction: 0) }
        }

        var weights: [ParentGenre: Double] = [:]
        var artistsWithGenres = 0

        for artist in artists {
            guard let genres = artistGenreCache[artist.id], !genres.isEmpty else { continue }
            let families = Set(genres.map(ParentGenre.classify))
            guard !families.isEmpty else { continue }
            artistsWithGenres += 1
            let share = 1.0 / Double(families.count)
            for family in families {
                weights[family, default: 0] += share
            }
        }

        guard artistsWithGenres > 0 else {
            return ParentGenre.allCases.map { MajorGenreShare(parentGenre: $0, fraction: 0) }
        }

        return ParentGenre.allCases
            .map { MajorGenreShare(parentGenre: $0, fraction: (weights[$0] ?? 0) / Double(artistsWithGenres)) }
            .sorted {
                $0.fraction != $1.fraction
                    ? $0.fraction > $1.fraction
                    : $0.parentGenre.displayName < $1.parentGenre.displayName
            }
    }

    /// How a single major genre's listening breaks down into its raw
    /// subgenre tags, as its own self-contained 100% (independent of
    /// `majorGenreBreakdown`'s cross-family split) -- e.g. "of the
    /// artists touching Electronic, 40% are tagged dubstep, 35% house."
    /// Every raw tag that classifies into `parentGenre`, across every
    /// artist, counts once -- an artist with two Electronic subgenres
    /// (dubstep + house) contributes to both, same "credit every tag"
    /// rule the flat bar-list breakdown already uses.
    func subgenreBreakdown(for parentGenre: ParentGenre, in range: TimeRange) -> [GenreShare] {
        guard let artists = topArtistsByRange[range] else { return [] }

        var counts: [String: Int] = [:]
        var totalTagInstances = 0

        for artist in artists {
            guard let genres = artistGenreCache[artist.id] else { continue }
            for genre in genres where ParentGenre.classify(genre) == parentGenre {
                counts[genre, default: 0] += 1
                totalTagInstances += 1
            }
        }

        guard totalTagInstances > 0 else { return [] }

        return counts
            .map { GenreShare(genre: $0.key, count: $0.value, fraction: Double($0.value) / Double(totalTagInstances)) }
            .sorted { $0.count > $1.count || ($0.count == $1.count && $0.genre < $1.genre) }
    }

    /// Resolves one artist's genres, getGenre.com first, falling back to
    /// Last.fm. getGenre is queried by exact Spotify artist ID (no name
    /// matching needed), returns genres already in relevance order, and
    /// showed no rate limiting in testing -- a much better fit than
    /// MusicBrainz's 1 req/sec limit, which this replaced. getGenre's
    /// licensing terms are ambiguous for a distributed app (CC
    /// BY-NC-SA license on the data vs. a "personal use only" clause in
    /// their generic Terms of Service that doesn't clearly address an
    /// app redistributing their API responses) -- accepted knowingly for
    /// now; worth emailing support@getgenre.com for explicit permission
    /// before any wider distribution (see README).
    ///
    /// Returns `nil` (meaning: don't cache anything, leave it to retry
    /// later) only if BOTH sources error out -- a transient network
    /// failure shouldn't permanently look identical to "neither source
    /// has genres for this artist", which legitimately caches `[]`.
    private func resolveGenres(for artist: SpotifyArtist) async -> [String]? {
        if let ggGenres = try? await GetGenreAPIClient.shared.fetchGenres(spotifyArtistID: artist.id) {
            let genres = Array(ggGenres.map { $0.lowercased() }.filter(Self.isGenreTag).prefix(tagsPerArtist))
            if !genres.isEmpty {
                #if DEBUG
                debugLog("GenreStatsStore: resolved \(genres.count) getGenre genre(s) for \"\(artist.name)\"")
                #endif
                return genres
            }
        }
        // getGenre either errored, had nothing, or had only noise tags
        // (filtered out by isGenreTag) -- try Last.fm before giving up.

        guard let tags = try? await LastFMAPIClient.shared.fetchTopTags(artistName: artist.name) else {
            #if DEBUG
            debugLog("GenreStatsStore: both getGenre and Last.fm lookups FAILED for \"\(artist.name)\"")
            #endif
            return nil
        }
        let genres = Array(tags.map { $0.name.lowercased() }.filter(Self.isGenreTag).prefix(tagsPerArtist))
        #if DEBUG
        debugLog("GenreStatsStore: getGenre had nothing for \"\(artist.name)\", used \(genres.count) Last.fm tag(s) instead")
        #endif
        return genres
    }

    // Known non-genre noise that Last.fm's free-form community tagging
    // (and occasionally getGenre) can return alongside real genres --
    // filtered out before anything is cached, counted, or shown as a
    // "genre" anywhere in the Stats tab. Lowercased since callers always
    // lowercase the raw tag before checking.
    private static let nonGenreTags: Set<String> = [
        "underrated", "overrated", "live", "seen live", "favorite", "favorites",
        "favourite", "favourites", "awesome", "amazing", "best", "guilty pleasure",
        "love", "legend", "legendary", "classic", "eletronic"
    ]

    /// True if `tag` (already lowercased) looks like an actual genre
    /// rather than noise. Two checks, not just a literal denylist: a
    /// fixed list of known junk words (opinions, "seen live", a typo'd
    /// "eletronic"), plus a *rule* that rejects any all-digit tag ("2",
    /// "90", a bare year) -- the rule generalizes to numeric junk this
    /// app hasn't seen yet, the same way the suffix-pattern keywords in
    /// `ParentGenre` generalize beyond the exact subgenres seen so far.
    private static func isGenreTag(_ tag: String) -> Bool {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.allSatisfy(\.isNumber) else { return false }
        return !nonGenreTags.contains(trimmed)
    }

    /// Tallies genre frequency across a top-artists list: every resolved
    /// genre tag an artist has counts once for that artist (equal weight
    /// per artist, not weighted by the artist's rank in the list or by
    /// Last.fm's per-tag weight), matching the "all of an artist's
    /// genres, equal weight" decision for this feature. `fraction` is
    /// out of the number of artists that resolved to at least one genre
    /// tag, since an artist with none (unresolved or genuinely untagged)
    /// shouldn't dilute the shares of artists that did resolve.
    private static func genreShares(for artists: [SpotifyArtist], using cache: [String: [String]]) -> [GenreShare] {
        var counts: [String: Int] = [:]
        var artistsWithGenres = 0

        for artist in artists {
            guard let genres = cache[artist.id], !genres.isEmpty else { continue }
            artistsWithGenres += 1
            for genre in genres {
                counts[genre, default: 0] += 1
            }
        }

        guard artistsWithGenres > 0 else { return [] }

        return counts
            .map { genre, count in
                GenreShare(genre: genre, count: count, fraction: Double(count) / Double(artistsWithGenres))
            }
            .sorted { $0.count > $1.count || ($0.count == $1.count && $0.genre < $1.genre) }
    }

    private func persistBreakdowns() {
        guard let loadedAt else { return }
        let cached = CachedBreakdowns(breakdowns: breakdowns, topArtistsByRange: topArtistsByRange, loadedAt: loadedAt)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: breakdownCacheKey)
    }

    private func persistTagCache() {
        guard let data = try? JSONEncoder().encode(artistGenreCache) else { return }
        UserDefaults.standard.set(data, forKey: tagCacheKey)
    }
}
