//
//  mochimixApp.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import SwiftUI
import UIKit

#if DEBUG
/// Appends a line to `debug_log.txt` in the shared App Group container.
/// Used by ItemNormalizer/SpotifyAPIClient's debug-only diagnostic logging
/// -- writing to a plain file (rather than relying only on `print()`) means
/// the trail is always inspectable on disk afterward, even when console
/// capture is unavailable. Never logs tokens.
func debugLog(_ message: String) {
    print("[mochimix debug] \(message)")
    let line = "\(Date()): \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = SharedStore.shared.containerURL.appendingPathComponent("debug_log.txt")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

#endif

private extension Notification.Name {
    static let spotifyBridgeURLReceived = Notification.Name("spotifyBridgeURLReceived")
}

private enum SpotifyBridgeHandoffState {
    static var suppressForegroundRefreshUntil: Date?
}

@main
struct mochimixApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootShellView()
                // Spotify redirects back to this app via the
                // "mochimix-login://callback" URL (registered in
                // mochimix/Info.plist). iOS delivers that URL here.
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Refresh whenever the app becomes active (first launch, or
            // coming back from the background) so the widget's data stays
            // reasonably current without the user having to think about it.
            guard newPhase == .active else { return }

            if let suppressUntil = SpotifyBridgeHandoffState.suppressForegroundRefreshUntil,
               suppressUntil > Date() {
                #if DEBUG
                debugLog("Skipping foreground refresh during Spotify widget-link handoff")
                #endif
                return
            }

            Task { await WidgetDataProvider.shared.refresh() }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        if url.scheme == "https", url.host == "open.spotify.com" {
            SpotifyBridgeHandoffState.suppressForegroundRefreshUntil = Date().addingTimeInterval(3)
            NotificationCenter.default.post(name: .spotifyBridgeURLReceived, object: nil)

            DispatchQueue.main.async {
                UIApplication.shared.open(url)
            }
            return
        }

        SpotifyAuthService.shared.handleRedirectIfNeeded(url: url)
    }
}


private struct RootShellView: View {
    @ObservedObject private var auth = SpotifyAuthService.shared
    @State private var showLaunchSplash = true
    @State private var headerHeight: CGFloat = 0

    var body: some View {
        ZStack {
            // The header floats over the pages (rather than sitting above
            // them) so it can share each page's translucent top-bar band;
            // pages read its height from `topChromeHeight` to make room.
            ContentView()
                .environment(\.topChromeHeight, auth.isLoggedIn ? headerHeight : 0)
                .overlay(alignment: .top) {
                    if auth.isLoggedIn {
                        AppHeaderView()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                headerHeight = $0
                            }
                    }
                }
            .opacity(showLaunchSplash ? 0 : 1)
            .animation(.easeInOut(duration: 0.35), value: showLaunchSplash)

            LaunchSplashView()
                .opacity(showLaunchSplash ? 1 : 0)
                .allowsHitTesting(showLaunchSplash)
                .zIndex(10)
                .animation(.easeInOut(duration: 0.35), value: showLaunchSplash)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                showLaunchSplash = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .spotifyBridgeURLReceived)) { _ in
            showLaunchSplash = false
        }
    }
}

private struct LaunchSplashView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var imageName: String {
        colorScheme == .dark ? "login-logo-dark" : "login-logo-light"
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            Group {
                if let uiImage = UIImage(named: imageName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    #if DEBUG
                    let _ = debugLog("Missing launch splash logo asset named \(imageName). Check Assets.xcassets image set name and target membership.")
                    #endif

                    Text("mochimix")
                        .font(.custom("Inter", size: 40).weight(.bold))
                        .foregroundStyle(AppTheme.primaryText)
                }
            }
            .frame(width: 400, height: 200)
        }
    }
}

/// The slim bar above every main page: the user's Spotify avatar (tap to
/// open their Spotify profile) on the left, the mochimix mark centered.
/// The mark is a template image tinted with `primaryText`, so its single
/// source PNG works in both light and dark mode.
private struct AppHeaderView: View {
    @ObservedObject private var profileStore = ProfileStore.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Image("mochimix-mark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 39)
                .foregroundStyle(AppTheme.primaryText)
                .accessibilityLabel("mochimix")

            HStack {
                Button {
                    if let url = profileStore.profileURL { openURL(url) }
                } label: {
                    ProfileAvatar(size: 42)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open your Spotify profile")

                Spacer()
            }
        }
        .frame(height: 47)
        .padding(.horizontal)
        .padding(.top, 4)
        // No background of its own: each page's PageTitle draws the
        // translucent top-bar band behind this header.
        // Profiles cached before the header linked out have no user ID yet.
        .task {
            if profileStore.userID == nil {
                await profileStore.refresh()
            }
        }
    }
}
