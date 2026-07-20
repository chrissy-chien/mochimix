//
//  WidgetSettings.swift
//  Shared (used by both the mochimix app and the mochimix-widget extension)
//
//  Created by Chrissy Chien on 7/8/26.
//

import SwiftUI

/// Which items the widget should display. Chosen on the app's Settings
/// screen and applies globally to every widget instance (this app doesn't
/// support per-widget-instance configuration).
enum WidgetMode: String, Codable, CaseIterable, Identifiable {
    case recentlyPlayed
    case pinned
    case hybrid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recentlyPlayed: return "Recently Played"
        case .pinned: return "Pinned Items"
        case .hybrid: return "Hybrid"
        }
    }

    var explanation: String {
        switch self {
        case .recentlyPlayed:
            return "Shows your most recent listening."
        case .pinned:
            return "Shows items you've pinned yourself."
        case .hybrid:
            return "Shows your most recent item, plus up to 4 pinned items."
        }
    }

    /// Pinning/unpinning items only makes sense when the widget is actually
    /// going to show pins.
    var allowsEditingPins: Bool {
        self == .pinned || self == .hybrid
    }
}

/// The set of fonts the user can pick from in Settings. The first 4 use
/// SwiftUI's built-in system font designs; the rest use `Font.custom` with
/// real bundled iOS system font families (not custom-shipped font files),
/// so there's enough options to actually exercise the horizontal font
/// selector's scrolling.
enum WidgetFontChoice: String, Codable, CaseIterable, Identifiable {
    case system
    case rounded
    case serif
    case monospaced
    case georgia
    case americanTypewriter
    case courier
    case baskerville
    case avenir
    case optima
    case academy
    case bodoni
    case cochin
    case futura
    case galvji
    case hiragina
    case cursive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "Default"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .monospaced: return "Monospace"
        case .georgia: return "Georgia"
        case .americanTypewriter: return "Typewriter"
        case .courier: return "Courier"
        case .baskerville: return "Baskerville"
        case .avenir: return "Avenir"
        case .optima: return "Optima"
        case .academy: return "Academy"
        case .bodoni: return "Bodoni"
        case .cochin: return "Cochin"
        case .futura: return "Futura"
        case .galvji: return "Galvji"
        case .hiragina: return "Hiragina"
        case .cursive: return "Cursive"
        }
    }

    /// SwiftUI's `Font.system(_:design:)` covers the 4 built-in designs;
    /// everything past that names a real iOS system font family directly.
    /// `Font.custom(_:size:relativeTo:)` still respects Dynamic Type
    /// scaling relative to the given text style, and if a name is ever
    /// wrong/unavailable, it silently falls back to the system font rather
    /// than crashing.
    func font(_ style: Font.TextStyle) -> Font {
        switch self {
        case .system: return .system(style)
        case .rounded: return .system(style, design: .rounded)
        case .serif: return .system(style, design: .serif)
        case .monospaced: return .system(style, design: .monospaced)
        case .georgia: return .custom("Georgia", size: baseSize(for: style), relativeTo: style)
        case .americanTypewriter: return .custom("AmericanTypewriter", size: baseSize(for: style), relativeTo: style)
        case .courier: return .custom("Courier", size: baseSize(for: style), relativeTo: style)
        case .baskerville: return .custom("Baskerville", size: baseSize(for: style), relativeTo: style)
        case .avenir: return .custom("Avenir-Book", size: baseSize(for: style), relativeTo: style)
        case .optima: return .custom("Optima-Regular", size: baseSize(for: style), relativeTo: style)
        case .academy: return .custom("AcademyEngravedLetPlain", size: baseSize(for: style), relativeTo: style)
        case .bodoni: return .custom("BodoniSvtyTwoSCITCTT-Book", size: baseSize(for: style), relativeTo: style)
        case .cochin: return .custom("Cochin", size: baseSize(for: style), relativeTo: style)
        case .futura: return .custom("Futura-Medium", size: baseSize(for: style), relativeTo: style)
        case .galvji: return .custom("Galvji", size: baseSize(for: style), relativeTo: style)
        case .hiragina: return .custom("HiraMinProN-W3", size: baseSize(for: style), relativeTo: style)
        case .cursive: return .custom("SnellRoundhand", size: baseSize(for: style), relativeTo: style)
        }
    }

    /// Approximate point sizes matching each text style's default system
    /// size, since `Font.custom(_:size:relativeTo:)` needs a concrete base
    /// size (unlike `.system(style)`, which infers one).
    private func baseSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }
}

/// The full bundle of widget-affecting settings, stored together as one
/// JSON blob in the shared App Group container (see SharedStore).
///
/// `backgroundID` refers to an entry in `Backgrounds/backgrounds.json`
/// (see BackgroundOption.swift) rather than a fixed Swift enum -- so new
/// backgrounds can be added by editing that JSON + dropping in a PNG,
/// without touching this file. `BackgroundManifest.resolve(id:)` looks up
/// the full option (image name + text color) from this id, falling back
/// gracefully if the id no longer matches anything in the manifest.
struct WidgetSettings: Codable, Equatable {
    var mode: WidgetMode = .recentlyPlayed
    var font: WidgetFontChoice = .system
    var backgroundID: String = BackgroundManifest.all.first?.id ?? BackgroundManifest.fallback[0].id
    var appColorScheme: AppColorScheme = .system

    static let `default` = WidgetSettings()
}
