//
//  GetGenreAuthService.swift
//  mochimix
//

import Foundation

/// Logs in to getGenre.com (OAuth2 password grant -- no browser/redirect,
/// unlike Spotify's PKCE flow) and caches the resulting access token in
/// the Keychain, re-logging in automatically once it expires.
///
/// Reuses `KeychainHelper` under new key names rather than Spotify's
/// (same Keychain *service* as Spotify's tokens, per that type's design
/// -- the service string namespaces this app's Keychain items from other
/// apps', not from each other; distinct keys are enough to keep these
/// separate from the Spotify tokens it already stores).
@MainActor
final class GetGenreAuthService {
    static let shared = GetGenreAuthService()

    private init() {}

    private enum Keys {
        static let accessToken = "getgenre_access_token"
        static let expiresAt = "getgenre_expires_at"
    }

    enum AuthError: LocalizedError {
        case invalidResponse
        case serverError(status: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "getGenre returned an unexpected response."
            case .serverError(let status, let body):
                #if DEBUG
                debugLog("getGenre auth error \(status): \(body)")
                #endif
                return "getGenre login failed (error \(status))."
            }
        }
    }

    // Single-flight: if multiple callers notice the token is missing/
    // expired at once, they share one login request instead of each
    // firing their own.
    private var loginTask: Task<String, Error>?

    /// Returns a currently-valid access token, logging in again first if
    // there's none cached or it's expired (with a small buffer).
    func validAccessToken() async throws -> String {
        if let token = KeychainHelper.get(forKey: Keys.accessToken),
           let expiresAtString = KeychainHelper.get(forKey: Keys.expiresAt),
           let expiresAt = Double(expiresAtString),
           Date().timeIntervalSince1970 < expiresAt - 60 {
            return token
        }
        return try await login()
    }

    /// Forces a fresh login even if a cached token looked valid -- used
    /// when a request gets a 401 anyway (e.g. the token was revoked
    /// early).
    func forceLogin() async throws -> String {
        try await login()
    }

    private func login() async throws -> String {
        if let loginTask {
            return try await loginTask.value
        }
        let task = Task { try await self.performLogin() }
        loginTask = task
        defer { loginTask = nil }
        return try await task.value
    }

    private func performLogin() async throws -> String {
        var request = URLRequest(url: GetGenreConfig.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "password"),
            URLQueryItem(name: "username", value: GetGenreConfig.email),
            URLQueryItem(name: "password", value: GetGenreConfig.password)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.serverError(status: http.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(GetGenreTokenResponse.self, from: data)
        let expiresAt = Date().addingTimeInterval(TimeInterval(decoded.expiresIn)).timeIntervalSince1970
        KeychainHelper.set(decoded.accessToken, forKey: Keys.accessToken)
        KeychainHelper.set(String(expiresAt), forKey: Keys.expiresAt)
        return decoded.accessToken
    }
}
