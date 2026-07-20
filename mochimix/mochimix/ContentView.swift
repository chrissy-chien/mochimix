//
//  ContentView.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import SwiftUI

/// The app's root view: shows LoginView while logged out, or a tab view
/// (Recent Items + Settings) once logged in.
struct ContentView: View {
    @ObservedObject private var auth = SpotifyAuthService.shared
    @ObservedObject private var pinStore = PinStore.shared
    @ObservedObject private var settingsStore = SettingsStore.shared
    @State private var lastError: String?

    var body: some View {
        Group {
            if auth.isLoggedIn {
                TabView {
                    RecentItemsView(pinStore: pinStore, settingsStore: settingsStore)
                        .tabItem { Label("Recent", systemImage: "clock.arrow.circlepath") }

                    SettingsView(settingsStore: settingsStore, auth: auth)
                        .tabItem { Label("Settings", systemImage: "gearshape") }
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
}

#Preview {
    ContentView()
}
