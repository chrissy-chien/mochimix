//
//  AppTheme.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import SwiftUI

/// Named colors from `Assets.xcassets`, each with a light/dark variant.
/// App-only (not `Shared/`) -- these color sets exist only in the app
/// target's asset catalog, not the widget extension's, so referencing
/// them from widget code would silently fail to resolve at runtime.
enum AppTheme {
    static let background = Color("AppBackground")
    static let primaryText = Color("PrimaryText")
    static let secondaryText = Color("SecondaryText")
    static let cardBackground = Color("CardBackground")
    static let subtleCardBackground = Color("SubtleCardBackground")
    static let iconPlaceholderBackground = Color("IconPlaceholderBackground")
    static let divider = Color("DividerColor")
    static let accent = Color("AccentColor")
    static let accentSoft = Color("AccentSoft")
}
