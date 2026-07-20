//
//  WidgetDataProvider.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation
import WidgetKit

/// Orchestrates the app's two refresh paths:
///
/// - `refresh()` -- a full network refresh: fetch recently-played from
///   Spotify, normalize it, cache the raw mode-independent result (so the
///   Recent tab always has something to show regardless of widget mode),
///   then recompute and push the widget's display data.
/// - `refreshWidgetDisplayOnly()` -- recomputes the widget's display data
///   from whatever's already cached, with **no network call**. Used after
///   pinning/unpinning/reordering (PinStore) or switching widget mode,
///   since neither of those needs fresh Spotify data, just a different
///   view of what we already fetched.
///
/// Both paths end the same way: cache artwork locally, write
/// `WidgetDisplayData` into the shared App Group container, and tell
/// WidgetKit to reload the widget's timeline so it picks up the change
/// immediately.
@MainActor
final class WidgetDataProvider {
    static let shared = WidgetDataProvider()

    private init() {}

    private static let widgetKind = "mochimix_widget"

    enum RefreshError: LocalizedError {
        case notLoggedIn
        case rateLimited(message: String? = nil)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return "Not logged in to Spotify."
            case .rateLimited(let message):
                return message ?? "Spotify is rate-limiting this app right now. Showing your last saved items."
            }
        }
    }

    /// Guards against duplicate concurrent refreshes -- both
    /// mochimixApp's scenePhase-triggered refresh and RecentItemsView's
    /// `.task` fire on the same "app became active" moment, and were
    /// found (via the debug log) to each independently run their own full
    /// normalization pass at once, doubling real Spotify request volume
    /// every single time the app was foregrounded. Concurrent callers now
    /// share one in-flight attempt instead, mirroring the same pattern
    /// SpotifyAuthService already uses for token refreshes.
    private var inFlightRefresh: Task<Result<[MochiMixItem], Error>, Never>?

    /// Minimum time between normal automatic Spotify refresh attempts when
    /// cached recent items are already available. This prevents harmless UI
    /// events like app foregrounding or returning to the Recent tab from
    /// repeatedly hitting Spotify. Manual pull-to-refresh passes `force: true`
    /// and bypasses this cache throttle.
    private let minimumRefreshInterval: TimeInterval = 120
    private var lastRefreshAttemptAt: Date?

    /// Fetches fresh data from Spotify. Returns the mode-independent
    /// normalized recent items (not the mode-applied widget display data)
    /// since that's what callers like the Recent tab want to show.
    @discardableResult
    func refresh(force: Bool = false) async -> Result<[MochiMixItem], Error> {
        let cached = SharedStore.shared.loadRecentItems()
        
        if !force,
           !cached.isEmpty,
           let cooldownUntil = SharedStore.shared.rateLimitedUntil,
           cooldownUntil > Date() {
            SharedStore.shared.lastFetchErrorMessage = rateLimitedMessage()
            await pushDisplayData(recentItems: cached)
            #if DEBUG
            debugLog("refresh(): rate-limit cooldown active until \(cooldownUntil) -- returning \(cached.count) cached item(s) without calling Spotify and recomputing widget display")
            #endif
            return .success(cached)
        }

        if !force,
           !cached.isEmpty,
           let lastRefreshAttemptAt,
           Date().timeIntervalSince(lastRefreshAttemptAt) < minimumRefreshInterval {
            await pushDisplayData(recentItems: cached)
            #if DEBUG
            let remaining = minimumRefreshInterval - Date().timeIntervalSince(lastRefreshAttemptAt)
            debugLog("refresh(): throttled automatic refresh -- returning \(cached.count) cached item(s), next Spotify refresh allowed in \(Int(ceil(remaining)))s, recomputed widget display")
            #endif
            return .success(cached)
        }

        if force {
            #if DEBUG
            debugLog("refresh(): user-initiated force refresh -- bypassing cache throttle")
            #endif
        }

        if let existing = inFlightRefresh {
            #if DEBUG
            debugLog("refresh(): a refresh is already in flight -- awaiting its result instead of starting a duplicate one")
            #endif
            return await existing.value
        }

        lastRefreshAttemptAt = Date()
        let task = Task<Result<[MochiMixItem], Error>, Never> { [weak self] in
            guard let self else { return .failure(RefreshError.notLoggedIn) }
            return await self.performRefresh()
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return await task.value
    }

    private func performRefresh() async -> Result<[MochiMixItem], Error> {
        guard SpotifyAuthService.shared.isLoggedIn else {
            SharedStore.shared.isLoggedIn = false
            #if DEBUG
            debugLog("refresh(): not logged in -- aborting")
            #endif
            return .failure(RefreshError.notLoggedIn)
        }

        do {
            let (recentItems, wasRateLimited) = try await ItemNormalizer.fetchNormalizedRecentItems(desiredCount: SpotifyConfig.displayItemCount)
            SharedStore.shared.isLoggedIn = true

            if wasRateLimited && recentItems.isEmpty {
                // A rate-limited run with nothing usable at all (not even
                // ItemNormalizer's degraded track/album fallback -- e.g.
                // the track's own album name was also blank) is a FAILED
                // refresh, not "Spotify has no history". It must never
                // overwrite good cached data, and the UI needs to be told
                // explicitly rather than silently treating an empty result
                // as trustworthy (that conflation was the reason Recently
                // Played stayed permanently blank even after cached data
                // existed).
                let cached = SharedStore.shared.loadRecentItems()
                let message = rateLimitedMessage()
                SharedStore.shared.lastFetchErrorMessage = message
                #if DEBUG
                debugLog("refresh(): rate-limited this attempt with nothing usable -- \(cached.isEmpty ? "no cache to fall back on" : "preserving \(cached.count) cached item(s)"), not overwriting")
                #endif
                if !cached.isEmpty {
                    await pushDisplayData(recentItems: cached)
                    return .success(cached)
                }
                return .failure(RefreshError.rateLimited(message: message))
            }

            // Note: `recentItems` can be non-empty even when `wasRateLimited`
            // is true -- ItemNormalizer degrades rate-limited context
            // lookups to the track's own album/track instead of dropping
            // them, since Spotify's real Retry-After for this app has been
            // observed as long as ~17 hours, and staying blank that whole
            // time is worse than a less-precisely-attributed real item.
            if recentItems.isEmpty {
                let cached = SharedStore.shared.loadRecentItems()
                guard cached.isEmpty else {
                    // Preserve the existing cache and widget display
                    // entirely -- don't touch SharedStore or the widget at
                    // all, just report the cached items back so the UI
                    // keeps showing what it already had.
                    #if DEBUG
                    debugLog("refresh(): 0 normalized items this attempt -- preserving \(cached.count) cached item(s), not overwriting")
                    #endif
                    await pushDisplayData(recentItems: cached)
                    SharedStore.shared.lastFetchErrorMessage = nil
                    return .success(cached)
                }
                // Nothing cached before either -- this looks like a
                // genuinely empty/new account rather than a failed
                // refresh, so let the empty state show accurately.
            }

            let mergedItems = mergeFreshItemsWithCachedHistory(recentItems)
            SharedStore.shared.saveRecentItems(mergedItems)
            await pushDisplayData(recentItems: mergedItems)
            SharedStore.shared.lastFetchErrorMessage = wasRateLimited
                ? rateLimitedMessage()
                : nil
            #if DEBUG
            debugLog("refresh(): success -- \(recentItems.count) fresh item(s), \(mergedItems.count) merged cached item(s) pushed to widget (wasRateLimited=\(wasRateLimited))")
            #endif
            return .success(mergedItems)
        } catch {
            SharedStore.shared.lastFetchErrorMessage = error.localizedDescription
            #if DEBUG
            debugLog("refresh(): failed with error: \(error)")
            #endif
            WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
            return .failure(error)
        }
    }

    /// Spotify's recently-played endpoint can lag behind the currently-playing
    /// endpoint. Without merging, a manual refresh while listening to playlist A
    /// shows A at the top, but switching to playlist B and refreshing replaces A
    /// with B until Spotify eventually writes A into play history.
    ///
    /// The important bit is preserving the previous cached top item directly
    /// under a brand-new top item. That makes the local recency order feel like:
    /// B is currently playing now, A was the item I was listening to just before
    /// it, then Spotify's normal recently-played results fill the rest.
    private func mergeFreshItemsWithCachedHistory(_ freshItems: [MochiMixItem]) -> [MochiMixItem] {
        let cachedItems = SharedStore.shared.loadRecentItems()
        var candidates: [MochiMixItem] = []

        if let freshTop = freshItems.first {
            candidates.append(freshTop)

            if let cachedTop = cachedItems.first,
               cachedTop.id != freshTop.id {
                candidates.append(cachedTop)
            }

            candidates.append(contentsOf: freshItems.dropFirst())
        } else {
            candidates.append(contentsOf: freshItems)
        }

        candidates.append(contentsOf: cachedItems)

        var seenIDs = Set<String>()
        var merged: [MochiMixItem] = []

        for item in candidates {
            guard !seenIDs.contains(item.id) else { continue }
            seenIDs.insert(item.id)
            merged.append(item)
            if merged.count >= SpotifyConfig.displayItemCount { break }
        }

        return merged
    }

    /// Recomputes the widget's display data from the already-cached recent
    /// items + current pins/mode, without hitting the network. Called by
    /// PinStore after every pin mutation, and by Settings whenever the
    /// widget mode changes.
    func refreshWidgetDisplayOnly() async {
        let recentItems = SharedStore.shared.loadRecentItems()
        await pushDisplayData(recentItems: recentItems)
    }

    private func pushDisplayData(recentItems: [MochiMixItem]) async {
        let mode = SharedStore.shared.settings.mode
        let display = computeDisplayData(mode: mode, recentItems: recentItems)
        let displayWithArtwork = await withArtworkCached(display)

        SharedStore.shared.saveWidgetItems(displayWithArtwork)
        let shownItems = ([displayWithArtwork.topItem] + displayWithArtwork.tileItems).compactMap { $0 }
        ImageCache.pruneUnusedArtwork(keeping: shownItems)

        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }

    /// Builds the widget's top item + 4 tiles for the given mode.
    ///
    /// - Recently Played: top = most recent item, tiles = the next 4.
    /// - Pinned: slot 0 is the top item, slots 1-4 are the tiles -- all in
    ///   the order the user arranged them, with empty slots shown as-is
    ///   (no backfill; "graceful empty placeholders" per spec).
    /// - Hybrid: top is always the most recent item (even if it duplicates
    ///   a pinned slot -- intentionally not deduped), tiles are pinned
    ///   slots 0-3 in their exact positions (slot 4 is Hybrid-disabled and
    ///   never contributes). Empty tile slots get backfilled with the next
    ///   distinct recent items not already shown, preserving position.
    private func computeDisplayData(mode: WidgetMode, recentItems: [MochiMixItem]) -> WidgetDisplayData {
        switch mode {
        case .recentlyPlayed:
            let top = recentItems.first
            let tiles = Array(recentItems.dropFirst().prefix(4))
            return WidgetDisplayData(topItem: top, tileItems: tiles)

        case .pinned:
            let slots = PinStore.shared.slots.slots
            let top = slots.first ?? nil
            let tiles = Array(slots.dropFirst().prefix(4))
            return WidgetDisplayData(topItem: top, tileItems: tiles)

        case .hybrid:
            let top = recentItems.first
            var tiles = Array(PinStore.shared.slots.slots.prefix(4))

            let alreadyShown = Set(tiles.compactMap { $0?.id })
            var backfill = recentItems
                .filter { $0.id != top?.id && !alreadyShown.contains($0.id) }
                .makeIterator()
            for index in tiles.indices where tiles[index] == nil {
                tiles[index] = backfill.next()
            }

            return WidgetDisplayData(topItem: top, tileItems: tiles)
        }
    }

    /// Downloads/caches artwork for the top item and each tile, filling in
    /// `localArtworkFileName` so the widget only ever needs to load images
    /// from disk.
    private func withArtworkCached(_ display: WidgetDisplayData) async -> WidgetDisplayData {
        var result = display

        if var top = result.topItem {
            top.localArtworkFileName = await ImageCache.cacheArtwork(for: top)
            result.topItem = top
        }

        var newTiles: [MochiMixItem?] = []
        for tile in result.tileItems {
            if var item = tile {
                item.localArtworkFileName = await ImageCache.cacheArtwork(for: item)
                newTiles.append(item)
            } else {
                newTiles.append(nil)
            }
        }
        result.tileItems = newTiles

        return result
    }
    // Helper for rate-limited error messages with remaining time, if available.
    private func rateLimitedMessage() -> String {
        if let cooldownUntil = SharedStore.shared.rateLimitedUntil {
            let remaining = max(0, cooldownUntil.timeIntervalSinceNow)
            if remaining > 0 {
                return "Spotify is rate-limiting detailed playlist/album lookups right now. Try again in \(remainingTimePhrase(for: remaining))."
            }
        }

        return "Spotify is rate-limiting detailed playlist/album lookups right now. Please try again shortly."
    }

    private func remainingTimePhrase(for seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int(ceil(seconds / 60)))

        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if minutes == 0 {
            return "\(hours) hr"
        }

        return "\(hours) hr \(minutes) min"
    }
}
