//
//  ContentView.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import SwiftUI

/// The app's root view: shows LoginView while logged out, or a swipeable
/// tab view (Recent / Stats / Settings) once logged in.
///
/// Uses `.tabViewStyle(.page)` (indicator hidden) rather than the plain
/// icon-bar style specifically because the plain style has no swipe
/// gesture between tabs at all -- `.page` is what gives swiping its
/// native, finger-tracking slide animation. The icon bar at the bottom
/// is a custom view (`mainTabBar`) rather than `.tabItem`, since `.page`
/// style doesn't render tab items; it just sets the same `selectedTab`
/// binding that swiping also drives, so tapping and swiping stay in sync.
struct ContentView: View {
    @ObservedObject private var auth = SpotifyAuthService.shared
    @ObservedObject private var pinStore = PinStore.shared
    @ObservedObject private var settingsStore = SettingsStore.shared
    @State private var lastError: String?
    @State private var selectedTab: MainTab = .recent

    enum MainTab: Int, CaseIterable {
        case recent, stats, settings

        var label: String {
            switch self {
            case .recent: return "Recent"
            case .stats: return "Stats"
            case .settings: return "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .recent: return "clock.arrow.circlepath"
            case .stats: return "chart.pie"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        Group {
            if auth.isLoggedIn {
                TabView(selection: $selectedTab) {
                    RecentItemsView(pinStore: pinStore, settingsStore: settingsStore, isActive: selectedTab == .recent)
                        .tag(MainTab.recent)

                    GenreStatsView(isActive: selectedTab == .stats)
                        .tag(MainTab.stats)

                    SettingsView(settingsStore: settingsStore, auth: auth, isActive: selectedTab == .settings)
                        .tag(MainTab.settings)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // The paged TabView clips pages to its frame; reaching the
                // top of the screen lets each page's top bar sit behind the
                // floating app header (see TopBar.swift).
                .ignoresSafeArea(.container, edges: .top)
                .safeAreaInset(edge: .bottom) {
                    mainTabBar
                }
            } else {
                LoginView(auth: auth, lastError: lastError)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        // The app's own dark/light override. The widget can't be affected
        // by this (separate process) -- its text-color-only equivalent is
        // handled directly in mochimix_widget.swift.
        .preferredColorScheme(settingsStore.settings.appColorScheme.colorScheme)
        .onAppear {
            lastError = SharedStore.shared.lastFetchErrorMessage
        }
        .onChange(of: auth.isLoggedIn) { _, isLoggedIn in
            if isLoggedIn {
                Task {
                    await WidgetDataProvider.shared.refresh()
                    await ProfileStore.shared.refresh()
                }
            } else {
                lastError = SharedStore.shared.lastFetchErrorMessage
            }
        }
    }

    private var mainTabBar: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases, id: \.self) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selectedTab = tab }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 20))
                        Text(tab.label)
                            .font(.caption2)
                    }
                    .foregroundStyle(isSelected ? Color.accentColor : AppTheme.secondaryText)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background {
            AppTheme.cardBackground.ignoresSafeArea(edges: .bottom)
        }
    }
}

#Preview {
    ContentView()
}
