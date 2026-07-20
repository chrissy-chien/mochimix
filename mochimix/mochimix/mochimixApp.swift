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

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                if auth.isLoggedIn {
                    AppHeaderView()

                    HeaderBackgroundFade()
                }

                ContentView()
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

private struct AppHeaderView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var imageName: String {
        colorScheme == .dark ? "header-dark" : "header-light"
    }

    var body: some View {
        Group {
            if let uiImage = UIImage(named: imageName) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 270)
            } else {
                #if DEBUG
                let _ = debugLog("Missing header asset named \(imageName). Check Assets.xcassets image set name and target membership.")
                #endif

                Text("mochimix")
                    .font(.custom("Inter", size: 40).weight(.bold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal)
        .padding(.top, 20)
        .padding(.bottom, 0)
        .background(AppTheme.background)
        .zIndex(2)
    }
}

private struct HeaderBackgroundFade: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.background)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.0),
                        .init(color: .black, location: 0.45),
                        .init(color: .black.opacity(0.0), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .padding(.bottom, -28)
            .zIndex(1)
    }
}
