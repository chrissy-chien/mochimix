//
//  KeychainHelper.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation
import Security

/// A minimal wrapper around Keychain Services (the `Security` framework)
/// for storing small secrets -- here, Spotify's access/refresh tokens.
///
/// This is app-only (not in the Shared/ folder): only the main app talks to
/// Spotify and stores its tokens. We deliberately do NOT configure a
/// Keychain Access Group to share these with the widget extension -- the
/// widget should never need Spotify credentials at all, since it only
/// displays data the app already fetched and cached (see SharedStore).
///
/// Keychain APIs are C-style and dictionary-based, which is why this reads
/// a bit differently from typical Swift code -- that's normal, not a sign
/// something's wrong.
enum KeychainHelper {
    /// Groups all of this app's Keychain items together under one "service"
    /// name, separate from any other app's Keychain items on the device.
    private static let service = "com.meowmeow.mochimix.spotify"

    static func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // The Keychain has no simple "update or insert" call -- the
        // straightforward way to always end up with exactly one item for
        // this key is to delete whatever's there first, then add the new
        // value.
        SecItemDelete(query as CFDictionary)

        var newItem = query
        newItem[kSecValueData as String] = data
        // "AfterFirstUnlock" means the token stays readable in the
        // background (e.g. for a widget refresh) after the device has been
        // unlocked once since restart, without requiring the device to be
        // unlocked at that exact moment.
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        SecItemAdd(newItem as CFDictionary, nil)
    }

    static func get(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
