//
//  mochimix_widget.swift
//  mochimix-widget
//
//  Created by Chrissy Chien on 7/8/26.
//

import WidgetKit
import SwiftUI

/// What the widget shows at any given moment. `display` is the mode-applied
/// top item + 4 tiles (see WidgetDisplayData) -- each slot is optional so
/// Hybrid/Pinned mode can leave a specific position empty without the row
/// silently compacting.
struct SimpleEntry: TimelineEntry {
    let date: Date
    let display: WidgetDisplayData
    let settings: WidgetSettings
    let isLoggedIn: Bool
    let lastFetchErrorMessage: String?
}

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

struct mochimix_widgetEntryView: View {
    var entry: Provider.Entry

    /// One fixed size used for the top artwork *and* every bottom tile, so
    /// text length, missing subtitles, or image aspect ratio can never
    /// change how big any artwork tile is.
    private let tileSize: CGFloat = 60
    private let tileSpacing: CGFloat = 16
    private let playButtonSize: CGFloat = 36

    /// The background chosen in Settings, resolved from the JSON manifest.
    /// This alone (not app dark/light mode) decides text and play-button
    /// color -- see BackgroundOption.swift.
    private var background: BackgroundOption {
        BackgroundManifest.resolve(id: entry.settings.backgroundID)
    }

    var body: some View {
        Group {
            if isCompletelyEmpty {
                emptyStateView
            } else {
                contentView
            }
        }
    }

    private var isCompletelyEmpty: Bool {
        entry.display.topItem == nil && entry.display.tileItems.allSatisfy { $0 == nil }
    }

    // MARK: - Main layout
    //
    // A GeometryReader splits the widget into two equal halves. The top
    // half holds the primary item (artwork + title/subtitle + play button);
    // the bottom half holds the 4-tile row, vertically centered *within
    // that half* -- i.e. evenly between the widget's middle line and its
    // bottom edge, not stuck to either.

    private var contentView: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topRow
                    .frame(height: (geo.size.height) / 2)
                bottomRow
                    .frame(height: (geo.size.height) / 2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 0)
        }
    }

    // The top item's Link fills the whole top half (art + title + subtitle
    // + any leftover space all open that item, same as before), with the
    // play button layered on top in its own corner as an independent tap
    // target. Neither of those is the widget's *background* -- the gap
    // between halves and the row's own outer padding aren't covered by any
    // Link, so taps there fall through to `.widgetURL(...)` below and open
    // the app instead, per the new "tap background -> open mochimix" rule.
    private var topRow: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let top = entry.display.topItem {
                    HStack(spacing: 12) {
                        Link(destination: top.spotifyURL) {
                            artwork(for: top, cornerRadius: 6)
                        }
                        Link(destination: top.spotifyURL) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(top.name)
                                    .font(entry.settings.font.font(.headline))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(primaryTextColor)
                                    .lineLimit(1)
                                if let subtitle = top.subtitle {
                                    Text(subtitle)
                                        .font(entry.settings.font.font(.caption))
                                        .foregroundStyle(secondaryTextColor)
                                        .lineLimit(1)
                                    }
                                }
                            }
                        Spacer(minLength: 0)
                        }
                } else {
                    HStack(spacing: 8) {
                        emptyTile(cornerRadius: 6)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Reserves room so the title/subtitle never render underneath
            // the play button in the corner.
            .padding(.trailing, playButtonSize + 8)

            playButton
        }
        .frame(maxWidth: .infinity)
    }

    /// Always Spotify's own generic link (never a specific item, never
    /// mochimix) -- opens the Spotify app via Universal Link, or the
    /// browser if it's not installed.
    private var playButton: some View {
        Link(destination: SpotifyConfig.genericSpotifyURL) {
            Group {
                if let uiImage = BundledResource.image(named: playButtonImageName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "play.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(primaryTextColor)
                }
            }
            .frame(width: playButtonSize, height: playButtonSize)
            .contentShape(Rectangle())
            .padding(.top, 12)
        }
    }

    private var playButtonImageName: String {
        background.color == .white ? "play_white" : "play_black"
    }

    private var bottomRow: some View {
        HStack(spacing: tileSpacing) {
            ForEach(0..<4, id: \.self) { index in
                if let item = entry.display.tileItems[index] {
                    Link(destination: item.spotifyURL) {
                        artwork(for: item, cornerRadius: 6)
                        .contentShape(Rectangle())
                    }
                } else {
                    emptyTile(cornerRadius: 6)
                }
            }
        }
        // Centering a fixed-width row (fixed tile size + fixed spacing)
        // inside the available width automatically yields equal left/right
        // margins, without hand-tuning per-device numbers. The empty
        // margins on either side aren't covered by any Link, so they fall
        // through to `.widgetURL(...)` too.
        .frame(maxWidth: .infinity)
    }

    // MARK: - Artwork, cropped to a centered square (or circle for artists)
    //
    // The frame is applied immediately after scaledToFill and *before*
    // clipShape, so the fill+crop always happens against a real square --
    // applying the frame afterwards (the previous bug) let non-square
    // artwork escape the crop and distort the layout. Artists use the same
    // square frame/size but clip to a Circle instead of a rounded rect, per
    // MochiMixItem.ItemType.isCircularArtwork.

    @ViewBuilder
    private func artwork(for item: MochiMixItem, cornerRadius: CGFloat) -> some View {
        let shape: AnyShape = item.type.isCircularArtwork
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

        if let fileName = item.localArtworkFileName,
           let uiImage = UIImage(contentsOfFile: SharedStore.shared.artworkDirectory.appendingPathComponent(fileName).path) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: tileSize, height: tileSize)
                .clipShape(shape)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1.5)
        } else {
            shape
                .fill(.thinMaterial)
                .frame(width: tileSize, height: tileSize)
                .overlay {
                    Image(systemName: symbolName(for: item.type))
                        .foregroundStyle(.secondary)
                }
        }
    }

    /// A subtle but visible placeholder for a slot that's intentionally
    /// empty (e.g. Pinned mode with fewer than 5 pins) -- "graceful", not
    /// invisible, so the grid still reads as complete/symmetrical.
    private func emptyTile(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.white.opacity(0.08))
            .frame(width: tileSize, height: tileSize)
    }

    private func symbolName(for type: MochiMixItem.ItemType) -> String {
        switch type {
        case .playlist: return "music.note.list"
        case .album: return "square.stack"
        case .artist: return "person.crop.circle"
        case .track: return "music.note"
        }
    }

    // MARK: - Text/play-button color from the selected background
    //
    // This comes entirely from the background's own manifest entry now --
    // app dark/light mode doesn't touch the widget at all (it only affects
    // the app's own appearance; see AppColorScheme.swift). Each background
    // image gets a hand-picked color so its text stays readable, which is
    // exactly what backgrounds.json's "color" field is for.

    private var primaryTextColor: Color {
        background.color == .white
            ? Color(hex: "E0E0E0")   // light text for dark backgrounds
            : Color(hex: "333333")   // dark text for light backgrounds
    }

    private var secondaryTextColor: Color {
        primaryTextColor.opacity(0.65)
    }

    // MARK: - Empty state (not logged in, or logged in with no data yet)

    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Image(systemName: entry.lastFetchErrorMessage != nil ? "exclamationmark.triangle" : "music.note")
                .font(.title2)
                .foregroundStyle(secondaryTextColor)
                .padding(.bottom, 12)
            Text(emptyStateMessage)
                .font(entry.settings.font.font(.caption))
                .foregroundStyle(secondaryTextColor)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.top, 12)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateMessage: String {
        if !entry.isLoggedIn {
            return "Log in to mochimix to see your recent Spotify activity"
        }
        if entry.lastFetchErrorMessage != nil {
            return "Couldn't refresh just now. Showing last known data in mochimix."
        }
        return "No recent items yet"
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

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }
}

