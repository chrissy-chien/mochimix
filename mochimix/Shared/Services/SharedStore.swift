//
//  SharedStore.swift
//  Shared (used by both the mochimix app and the mochimix-widget extension)
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation

/// SharedStore is the one place that reads/writes the App Group container --
/// the shared sandbox folder that both the main app and the widget
/// extension are allowed to access, because both targets' entitlements list
/// the same App Group ("group.com.meowmeow.mochimix").
///
/// Why this matters: a widget extension runs in its own separate process,
/// sandboxed away from the main app. It can't read the app's normal
/// UserDefaults or Documents folder. An App Group creates one shared folder
/// (and one shared UserDefaults "suite") that both processes can see, and
/// this class is the single choke point for that -- nothing else in the
/// codebase needs to know the container's exact path or key names.
final class SharedStore {
    static let shared = SharedStore()

    /// UserDefaults backed by the App Group instead of the app's private
    /// UserDefaults. Both the app and widget read/write this exact suite.
    private let defaults: UserDefaults

    /// A folder inside the App Group container (a real folder on disk)
    /// where we keep things bigger/more structured than UserDefaults is
    /// meant for: the current widget item list (as JSON) and cached
    /// artwork image files.
    let containerURL: URL

    private init() {
        guard let defaults = UserDefaults(suiteName: SpotifyConfig.appGroupIdentifier) else {
            fatalError("Could not open App Group UserDefaults for \(SpotifyConfig.appGroupIdentifier). Check that the 'App Groups' capability is enabled and matches this identifier in both targets.")
        }
        self.defaults = defaults

        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SpotifyConfig.appGroupIdentifier) else {
            fatalError("Could not resolve App Group container URL for \(SpotifyConfig.appGroupIdentifier). Check that the 'App Groups' capability is enabled and matches this identifier in both targets.")
        }
        self.containerURL = container

        // Make sure the artwork subfolder exists up front, so ImageCache
        // never has to check for it before writing a file.
        try? FileManager.default.createDirectory(at: containerURL.appendingPathComponent("Artwork", isDirectory: true), withIntermediateDirectories: true)
    }

    var artworkDirectory: URL {
        containerURL.appendingPathComponent("Artwork", isDirectory: true)
    }

    // MARK: - Widget display data (the mode-applied top item + 4 tiles the widget renders)
    //
    // This is fully regenerable (WidgetDataProvider recomputes it from
    // `recentItems` + pins any time it runs), so if the on-disk shape ever
    // changes and fails to decode, we just fall back to `.empty` instead of
    // needing a real migration -- nothing the user did is lost.

    private let widgetDisplayFileName = "widget_display.json"

    func loadWidgetItems() -> WidgetDisplayData {
        let url = containerURL.appendingPathComponent(widgetDisplayFileName)
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return (try? JSONDecoder().decode(WidgetDisplayData.self, from: data)) ?? .empty
    }

    func saveWidgetItems(_ display: WidgetDisplayData) {
        let url = containerURL.appendingPathComponent(widgetDisplayFileName)
        guard let data = try? JSONEncoder().encode(display) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Recent items (mode-independent normalized recently-played list)
    //
    // Separate from the widget's display data above: this is always "the
    // last 5 distinct normalized source items from Spotify history",
    // regardless of widget mode, so the app's Recent tab can show it even
    // in Hybrid/Pinned mode (where the widget itself is showing something
    // else). WidgetDataProvider also reuses this cache to recompute the
    // widget's display data without a network re-fetch (e.g. after a pin
    // change or mode switch).

    private let recentItemsFileName = "recent_items.json"

    func loadRecentItems() -> [MochiMixItem] {
        let url = containerURL.appendingPathComponent(recentItemsFileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([MochiMixItem].self, from: data)) ?? []
    }

    func saveRecentItems(_ items: [MochiMixItem]) {
        let url = containerURL.appendingPathComponent(recentItemsFileName)
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Widget settings (mode, font, background -- set in the app's Settings screen)

    private let settingsKey = "widget_settings"

    var settings: WidgetSettings {
        get {
            guard let data = defaults.data(forKey: settingsKey),
                  let decoded = try? JSONDecoder().decode(WidgetSettings.self, from: data) else {
                return .default
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: settingsKey)
        }
    }

    // MARK: - Pinned slots (persisted here so the widget can read them too)
    //
    // Stored as ordered slots (see PinnedSlots) rather than a plain array,
    // so a specific position can be empty without disturbing the others.
    // This used to be an unordered, append-only `[MochiMixItem]` under the
    // "pinned_items" key -- real user data, so on first access after this
    // change we migrate whatever was there into slots 0..<min(5, count)
    // instead of silently discarding it.

    private let pinnedSlotsKey = "pinned_slots"
    private let legacyPinnedItemsKey = "pinned_items"

    var pinnedSlots: PinnedSlots {
        get {
            if let data = defaults.data(forKey: pinnedSlotsKey),
               let decoded = try? JSONDecoder().decode(PinnedSlots.self, from: data) {
                return decoded
            }

            // No slots saved yet -- check for pre-migration legacy data.
            if let legacyData = defaults.data(forKey: legacyPinnedItemsKey),
               let legacyItems = try? JSONDecoder().decode([MochiMixItem].self, from: legacyData),
               !legacyItems.isEmpty {
                let migrated = PinnedSlots(slots: legacyItems.map { $0 })
                pinnedSlots = migrated // persists under the new key
                defaults.removeObject(forKey: legacyPinnedItemsKey)
                return migrated
            }

            return .empty
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: pinnedSlotsKey)
        }
    }

    // MARK: - Login status flag
    //
    // The widget can't safely read the Keychain-stored Spotify tokens
    // itself (see SpotifyAuthService/KeychainHelper), but it still needs to
    // know "is the user logged in at all?" so it can show a "log in to see
    // your recent items" message instead of an empty grid. The app updates
    // this flag whenever auth state changes.

    private let isLoggedInKey = "is_logged_in"

    var isLoggedIn: Bool {
        get { defaults.bool(forKey: isLoggedInKey) }
        set { defaults.set(newValue, forKey: isLoggedInKey) }
    }

    // MARK: - Last fetch error (so the widget can show something useful if
    // the app's last background refresh failed, e.g. Spotify was unreachable)

    private let lastErrorKey = "last_fetch_error"

    var lastFetchErrorMessage: String? {
        get { defaults.string(forKey: lastErrorKey) }
        set { defaults.set(newValue, forKey: lastErrorKey) }
    }

    // MARK: - Rate-limit cooldown (app-only, but persisted so it survives
    // relaunches -- a full app quit/relaunch during testing must not reset
    // this back to "try immediately", since that's exactly what was
    // keeping a real Spotify rate limit from ever clearing.)

    private let rateLimitedUntilKey = "rate_limited_until"

    var rateLimitedUntil: Date? {
        get {
            let value = defaults.double(forKey: rateLimitedUntilKey)
            guard value > 0 else { return nil }
            return Date(timeIntervalSince1970: value)
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: rateLimitedUntilKey)
            } else {
                defaults.removeObject(forKey: rateLimitedUntilKey)
            }
        }
    }

}
