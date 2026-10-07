//
//  RecentItemsView.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import SwiftUI

/// Shows the 5 most recent normalized source items as a compact,
/// informational list -- this is mode-independent, so it's the same list
/// regardless of whether the widget itself is currently showing Recently
/// Played, Hybrid, or Pinned Items. When the widget mode is Hybrid or
/// Pinned Items, the pinned-slots editor (PinnedSlotsView) appears below
/// it, since that's the only place pinning happens now (via Spotify
/// search, not from this list).
struct RecentItemsView: View {

    private func refreshOnFirstLoadIfNeeded() async {
        // Avoid hitting Spotify every time the user switches away from and
        // back to the Recent page. Cached items should display immediately;
        // the user can still pull to refresh when they explicitly want fresh
        // data.
        guard items.isEmpty else {
            errorMessage = SharedStore.shared.lastFetchErrorMessage
            return
        }

        await refresh(isUserInitiated: false)
    }
    @ObservedObject var pinStore: PinStore
    @ObservedObject var settingsStore: SettingsStore
    let isActive: Bool

    @State private var items: [MochiMixItem] = SharedStore.shared.loadRecentItems()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var errorBubbleOpacity = 0.0
    @State private var errorBubbleOffsetY: CGFloat = -6
    @State private var errorBubbleDismissTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollResettingPage(isActive: isActive, onRefresh: { await refresh(isUserInitiated: true) }) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Recent")
                        .font(.largeTitle.bold())
                        .foregroundStyle(AppTheme.primaryText)

                    recentSection

                    if settingsStore.settings.mode.allowsEditingPins {
                        pinnedSection
                    }
                }
                .padding()
            }
            .background(AppTheme.background.ignoresSafeArea())
            .task { await refreshOnFirstLoadIfNeeded() }
            .overlay(alignment: .bottom) {
                if isLoading && !items.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Refreshing…")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .floatingStatusBubble()
                } else if let errorMessage, !items.isEmpty {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .floatingStatusBubble()
                        .opacity(errorBubbleOpacity)
                        .offset(y: errorBubbleOffsetY)
                }
            }
            .onChange(of: errorMessage) { _, newValue in
                if newValue != nil, !items.isEmpty {
                    showErrorBubble()
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recently Played")
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)

            VStack(alignment: .leading, spacing: 8) {
                if isLoading && items.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading your recent listening…")
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else if items.isEmpty {
                    Text(errorMessage ?? "Play something on Spotify, then pull to refresh.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                } else {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            RecentItemRow(item: item)

                            if item.id != items.last?.id {
                                Rectangle()
                                    .fill(AppTheme.divider)
                                    .frame(height: 1)
                                    .padding(.leading, 60)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
            .sectionCardBackground()
        }
        .padding(.top, -12)
        .padding(.bottom, -12)
    }

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pinned")
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 10) {
                PinnedSlotsView(pinStore: pinStore, mode: settingsStore.settings.mode)
                    .padding(.vertical, 6)

                Text(settingsStore.settings.mode == .hybrid
                     ? "In Hybrid mode, the widget's top spot is always your most recently played item."
                     : "Tap to search Spotify for a playlist, album, or artist to pin.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .sectionCardBackground()
        }
    }

    private func refresh(isUserInitiated: Bool) async {
        isLoading = true
        let result = await WidgetDataProvider.shared.refresh(force: isUserInitiated)
        switch result {
        case .success(let newItems):
            items = newItems
            // A "success" here can still be a rate-limited attempt that
            // fell back to cached items (see WidgetDataProvider.refresh())
            // -- lastFetchErrorMessage carries that explanation when so,
            // and is nil on a genuine full success.
            errorMessage = SharedStore.shared.lastFetchErrorMessage
            if errorMessage != nil, !items.isEmpty {
                showErrorBubble()
            }
            #if DEBUG
            debugLog("RecentItemsView: refresh success -- displaying \(newItems.count) item(s)\(errorMessage != nil ? " (rate-limited, showing cache)" : "")")
            #endif
        case .failure(let error):
            let hadCachedData = !items.isEmpty
            items = SharedStore.shared.loadRecentItems()
            if isUserInitiated || !hadCachedData {
                // Either the user explicitly asked and got nothing, or
                // there's no cached data to fall back on either way --
                // both are worth surfacing.
                errorMessage = error.localizedDescription
                if !items.isEmpty {
                    showErrorBubble()
                }
            } else {
                // A background refresh failed, but cached data is still
                // showing -- not worth interrupting the user for.
                errorMessage = nil
                #if DEBUG
                debugLog("background refresh failed silently (cached recent items retained): \(error)")
                #endif
            }
            #if DEBUG
            debugLog("RecentItemsView: refresh failed (\(error)) -- displaying \(items.count) item(s)")
            #endif
        }
        isLoading = false
    }

    private func showErrorBubble() {
        errorBubbleDismissTask?.cancel()

        errorBubbleOpacity = 0
        errorBubbleOffsetY = -6

        withAnimation(.easeOut(duration: 0.28)) {
            errorBubbleOpacity = 1
            errorBubbleOffsetY = 0
        }

        errorBubbleDismissTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.35)) {
                    errorBubbleOpacity = 0
                }
            }
        }
    }
}

private struct RecentItemRow: View {
    let item: MochiMixItem

    var body: some View {
        // Opens the item's Spotify page (Universal Link into the Spotify
        // app, browser fallback otherwise). This list is purely
        // informational -- it has no pin/select action of its own (pinning
        // only happens via PinnedSlotsView/PinSearchView), so there's
        // nothing for a tap-to-open action to conflict with here.
        Link(destination: item.spotifyURL) {
            HStack(spacing: 12) {
                artwork
                    .frame(width: 56, height: 56)
                    .clipShape(artworkShape)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.body)
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = item.artworkURL {
            // The in-app screen is allowed to load images over the network
            // directly (unlike the widget) since it's running in the app's
            // own process, not a widget extension.
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        artworkShape
            .fill(AppTheme.iconPlaceholderBackground)
            .overlay {
                Image(systemName: symbolName)
                    .foregroundStyle(AppTheme.secondaryText)
            }
    }

    /// Circle for artists, rounded-corner square for everything else.
    private var artworkShape: AnyShape {
        item.type.isCircularArtwork
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var symbolName: String {
        switch item.type {
        case .playlist: return "music.note.list"
        case .album: return "square.stack"
        case .artist: return "person.crop.circle"
        case .track: return "music.note"
        }
    }
}

#Preview {
    RecentItemsView(pinStore: .shared, settingsStore: .shared, isActive: true)
}

private extension View {
    func sectionCardBackground() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.cardBackground)
            }
    }

    func floatingStatusBubble() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.accentSoft.opacity(0.9))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .allowsHitTesting(false)
    }
}
