//
//  mochimix_widget.swift
//  mochimix-widget
//
//  Created by Chrissy Chien on 7/8/26.
//

import WidgetKit
import SwiftUI

// A widget extension is its own separate process from the main app, and
// WidgetKit strongly discourages widgets from making their own network
// calls. So this provider NEVER talks to Spotify -- it only reads whatever
// the app most recently wrote into the shared App Group container via
// SharedStore. The app (WidgetDataProvider) is responsible for fetching
// fresh data and calling WidgetCenter.shared.reloadTimelines(...) after.
struct Provider: TimelineProvider {
    // Shown briefly while the widget is first loading/redacted in the
    // widget gallery, before real data is available.
    func placeholder(in context: Context) -> SimpleEntry {
        let mock = MochiMixItem.mockItems
        let display = WidgetDisplayData(topItem: mock.first, tileItems: Array(mock.dropFirst().prefix(4)))
        return SimpleEntry(date: Date(), display: display, settings: .default, isLoggedIn: true, lastFetchErrorMessage: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        let entry = currentEntry()
        // We ask iOS to re-invoke this provider again in ~10 minutes. This
        // is a *request*, not a guarantee -- iOS decides the actual refresh
        // budget based on things like how often the user looks at this
        // widget. Since this provider only re-reads the shared cache (no
        // network), even a late refresh just means slightly stale cached
        // data, not a failure.
        let nextRefresh = Date().addingTimeInterval(10 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func currentEntry() -> SimpleEntry {
        let store = SharedStore.shared
        return SimpleEntry(
            date: Date(),
            display: store.loadWidgetItems(),
            settings: store.settings,
            isLoggedIn: store.isLoggedIn,
            lastFetchErrorMessage: store.lastFetchErrorMessage
        )
    }
}

struct mochimix_widget: Widget {
    let kind: String = "mochimix_widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            mochimix_widgetEntryView(entry: entry)
                // Fallback destination for areas not covered by explicit
                // Links. A full-widget transparent Link can steal taps from
                // nested item/play Links on device, causing every tap to open
                // mochimix. `.widgetURL` is the intended fallback mechanism.
                //.widgetURL(SpotifyConfig.openAppURL)
                .containerBackground(for: .widget) {
                    BackgroundImage(option: BackgroundManifest.resolve(id: entry.settings.backgroundID))
                }
        }
        .configurationDisplayName("mochimix")
        .description("Your recent Spotify listening.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

#Preview(as: .systemMedium) {
    mochimix_widget()
} timeline: {
    let mock = MochiMixItem.mockItems
    SimpleEntry(
        date: .now,
        display: WidgetDisplayData(topItem: mock.first, tileItems: Array(mock.dropFirst().prefix(4))),
        settings: .default,
        isLoggedIn: true,
        lastFetchErrorMessage: nil
    )
    SimpleEntry(
        date: .now,
        display: WidgetDisplayData(topItem: mock[0], tileItems: [mock[1], nil, mock[2], nil]),
        settings: .default,
        isLoggedIn: true,
        lastFetchErrorMessage: nil
    )
    SimpleEntry(date: .now, display: .empty, settings: .default, isLoggedIn: true, lastFetchErrorMessage: nil)
    SimpleEntry(date: .now, display: .empty, settings: .default, isLoggedIn: false, lastFetchErrorMessage: nil)
    SimpleEntry(date: .now, display: .empty, settings: .default, isLoggedIn: true, lastFetchErrorMessage: "network error")
}
