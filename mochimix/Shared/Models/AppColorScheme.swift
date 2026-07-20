//
//  AppColorScheme.swift
//  Shared (used by both the mochimix app and the mochimix-widget extension)
//
//  Created by Chrissy Chien on 7/8/26.
//

import SwiftUI

/// The user's chosen appearance, set once in Settings and used two
/// different ways:
///  - In the app, this drives `.preferredColorScheme(...)` on the root
///    view, overriding the whole app's light/dark appearance.
///  - In the widget, this only changes text foreground colors (see
///    mochimix_widget.swift) -- widgets aren't affected by the host app's
///    `.preferredColorScheme` at all (separate process), and we don't want
///    it touching the background image or artwork, just the text.
enum AppColorScheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` means "don't override" -- used directly with
    /// `.preferredColorScheme(_:)` in the app.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
