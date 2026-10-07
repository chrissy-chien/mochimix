//
//  SpotifyAuthService.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation
import Combine
import AuthenticationServices
import CryptoKit
import UIKit

/// Handles logging in to Spotify using the "Authorization Code with PKCE"
/// flow, and keeping the resulting access token fresh afterwards.
///
/// A quick primer on why PKCE, for reference: normally an OAuth app proves
/// its identity to the server with a permanent "client secret". But a
/// secret baked into an iOS app isn't actually secret -- anyone could
/// extract it from the app binary. PKCE (Proof Key for Code Exchange) fixes
/// this by having the app generate a random, one-time-use secret (the
/// "code verifier") for each login attempt instead. That's why you'll never
/// see a client secret anywhere in this file or in SpotifyConfig.
///
/// This class is app-only (not in Shared/) -- per the project's
/// architecture, the widget extension never authenticates or talks to
/// Spotify directly; it only displays data this class's app process already
/// fetched and cached.
@MainActor
final class SpotifyAuthService: NSObject, ObservableObject {
    static let shared = SpotifyAuthService()

    /// True once we have a refresh token stored, i.e. the user has
    /// completed login at least once (doesn't guarantee the access token
    /// is currently valid -- that's checked/refreshed lazily in
    /// `validAccessToken()`).
    @Published private(set) var isLoggedIn: Bool

    private override init() {
        self.isLoggedIn = KeychainHelper.get(forKey: Keys.refreshToken) != nil
        super.init()
    }

    private enum Keys {
        static let accessToken = "spotify_access_token"
        static let refreshToken = "spotify_refresh_token"
        static let expiresAt = "spotify_expires_at"
    }

    /// The PKCE "code verifier" generated when we start a login attempt.
    /// We hold onto it in memory only for as long as the system's login
    /// sheet is open, then use it once to exchange the returned code for
    /// tokens.
    private var pendingCodeVerifier: String?

    /// Keeping a strong reference to the session is required -- otherwise
    /// ARC could deallocate it mid-flow and the login sheet would vanish.
    private var webAuthSession: ASWebAuthenticationSession?

    // MARK: - Starting login

    /// Opens Spotify's login/consent screen in a system-provided secure web
    /// view (`ASWebAuthenticationSession`), which knows to hand control back
    /// to this app when Spotify redirects to our `mochimix-login://` scheme.
    func startLogin() {
        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Self.codeChallenge(for: verifier)
        pendingCodeVerifier = verifier

        var components = URLComponents(url: SpotifyConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: SpotifyConfig.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyConfig.redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: SpotifyConfig.scope),
        ]

        guard let authURL = components.url, let scheme = SpotifyConfig.redirectURI.scheme else {
            SharedStore.shared.lastFetchErrorMessage = "Could not build Spotify login URL."
            return
        }

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { [weak self] callbackURL, error in
            guard let self else { return }
            Task { @MainActor in
                guard let callbackURL, error == nil else {
                    self.pendingCodeVerifier = nil
                    return
                }
                await self.handleRedirect(url: callbackURL)
            }
        }
        session.presentationContextProvider = self
        // Ephemeral = don't share cookies with the user's normal Safari
        // session, and don't leave a persistent login trace in the web
        // view. Since this app only needs read access and nothing else
        // depends on staying signed into open.spotify.com in a browser,
        // this is the more private default.
        session.prefersEphemeralWebBrowserSession = true
        self.webAuthSession = session
        session.start()
    }

    /// mochimixApp's `onOpenURL` calls this too, as a defensive fallback --
    /// in the normal case `ASWebAuthenticationSession`'s own callback above
    /// already handles the redirect, so this is mostly a no-op safety net.
    func handleRedirectIfNeeded(url: URL) {
        guard url.scheme == SpotifyConfig.redirectURI.scheme, pendingCodeVerifier != nil else { return }
        Task { await handleRedirect(url: url) }
    }

    private func handleRedirect(url: URL) async {
        defer { pendingCodeVerifier = nil }

        guard let verifier = pendingCodeVerifier,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            SharedStore.shared.lastFetchErrorMessage = "Spotify login was cancelled or didn't return a code."
            return
        }

        do {
            try await exchangeCodeForTokens(code: code, verifier: verifier)
            isLoggedIn = true
            SharedStore.shared.isLoggedIn = true
            SharedStore.shared.lastFetchErrorMessage = nil
        } catch {
            SharedStore.shared.lastFetchErrorMessage = "Login failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Token exchange / refresh

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }

    private func exchangeCodeForTokens(code: String, verifier: String) async throws {
        let params = [
            "client_id": SpotifyConfig.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyConfig.redirectURI.absoluteString,
            "code_verifier": verifier,
        ]
        let tokens: TokenResponse = try await Self.postForm(to: SpotifyConfig.tokenURL, params: params)
        store(tokens)
    }

    /// Refreshes the access token using the stored refresh token. Spotify's
    /// PKCE refresh flow needs no client secret either -- just the client
    /// ID and the refresh token.
    private func refreshAccessToken() async throws {
        guard let refreshToken = KeychainHelper.get(forKey: Keys.refreshToken) else {
            throw AuthError.notLoggedIn
        }
        let params = [
            "client_id": SpotifyConfig.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        let tokens: TokenResponse = try await Self.postForm(to: SpotifyConfig.tokenURL, params: params)
        store(tokens)
    }

    private func store(_ tokens: TokenResponse) {
        KeychainHelper.set(tokens.access_token, forKey: Keys.accessToken)
        // Spotify doesn't always send back a new refresh token on refresh
        // calls -- when it doesn't, we keep using the one we already have.
        if let newRefreshToken = tokens.refresh_token {
            KeychainHelper.set(newRefreshToken, forKey: Keys.refreshToken)
        }
        let expiresAt = Date().addingTimeInterval(TimeInterval(tokens.expires_in))
        KeychainHelper.set(String(expiresAt.timeIntervalSince1970), forKey: Keys.expiresAt)
    }

    /// Returns a currently-valid access token, transparently refreshing it
    /// first if it's expired or about to be. `SpotifyAPIClient` calls this
    /// before every request instead of reading the Keychain directly, so
    /// the rest of the app never has to think about token expiry.
    func validAccessToken() async throws -> String {
        guard let token = KeychainHelper.get(forKey: Keys.accessToken) else {
            #if DEBUG
            debugLog("SpotifyAuthService: validAccessToken -- no access token stored (not logged in)")
            #endif
            throw AuthError.notLoggedIn
        }

        let expiresAt = KeychainHelper.get(forKey: Keys.expiresAt)
            .flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) } ?? .distantPast

        // Refresh a little early (60s buffer) instead of waiting until the
        // exact expiry instant.
        if expiresAt.timeIntervalSinceNow > 60 {
            return token
        }

        return try await refreshAccessTokenSingleFlight()
    }

    /// Unconditionally refreshes the access token, ignoring our locally
    /// cached expiry time. SpotifyAPIClient calls this if a request comes
    /// back 401 even though `validAccessToken()` thought the token was
    /// still valid -- e.g. if the token was revoked early on Spotify's end.
    func forceRefreshAccessToken() async throws -> String {
        try await refreshAccessTokenSingleFlight()
    }

    /// Holds the in-progress refresh request, if any, so concurrent callers
    /// share one attempt instead of each firing their own.
    private var inFlightRefresh: Task<String, Error>?

    /// Multiple callers can each notice the token needs refreshing around
    /// the same time -- e.g. `SpotifyAPIClient.search` used to fire 3
    /// requests concurrently, each independently calling
    /// `validAccessToken()`. Without this guard, each would read the same
    /// not-yet-rotated refresh token from Keychain and send its own
    /// POST /api/token; if Spotify rotates/invalidates the refresh token on
    /// first use (typical for PKCE clients), the other concurrent attempts
    /// get rejected, which could plausibly fail multiple requests at once
    /// that all merely needed a fresh token. This makes every concurrent
    /// caller await the *same* single in-flight refresh instead.
    private func refreshAccessTokenSingleFlight() async throws -> String {
        if let existing = inFlightRefresh {
            return try await existing.value
        }

        let task = Task<String, Error> { [weak self] in
            guard let self else { throw AuthError.notLoggedIn }
            do {
                try await self.refreshAccessToken()
                #if DEBUG
                debugLog("SpotifyAuthService: token refresh succeeded")
                #endif
            } catch {
                #if DEBUG
                debugLog("SpotifyAuthService: token refresh FAILED: \(error)")
                #endif
                throw error
            }
            guard let refreshed = KeychainHelper.get(forKey: Keys.accessToken) else {
                throw AuthError.notLoggedIn
            }
            return refreshed
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    func logOut() {
        KeychainHelper.remove(forKey: Keys.accessToken)
        KeychainHelper.remove(forKey: Keys.refreshToken)
        KeychainHelper.remove(forKey: Keys.expiresAt)
        isLoggedIn = false
        SharedStore.shared.isLoggedIn = false
        SharedStore.shared.saveRecentItems([])
        SharedStore.shared.saveWidgetItems(.empty)
        ProfileStore.shared.clear()
        GenreStatsStore.shared.clear()
    }

    enum AuthError: LocalizedError {
        case notLoggedIn
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "Not logged in to Spotify."
            case .serverError(let message): return message
            }
        }
    }

    // MARK: - PKCE + networking helpers

    private static func randomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hashed = SHA256.hash(data: Data(verifier.utf8))
        return Data(hashed).base64URLEncodedString()
    }

    private static func postForm<T: Decodable>(to url: URL, params: [String: String]) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params
            .map { key, value in "\(key.urlFormEncoded)=\(value.urlFormEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.serverError("Spotify returned status \(http.statusCode): \(body)")
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension SpotifyAuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Anchors the system login sheet to the app's current key window.
        // This is only ever called while a visible SwiftUI view is calling
        // startLogin(), so an active window scene is guaranteed to exist.
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first else {
            fatalError("No window scene available to present Spotify login.")
        }
        return window
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlFormValueAllowed) ?? self
    }
}

private extension CharacterSet {
    static let urlFormValueAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
