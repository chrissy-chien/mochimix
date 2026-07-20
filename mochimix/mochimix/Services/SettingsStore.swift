//
//  SettingsStore.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation
import Combine

/// Manages the widget mode / font / background choices made on the
/// Settings screen. Backed by SharedStore, so whatever's saved here is
/// exactly what the widget reads when it next renders.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: WidgetSettings {
        didSet {
            SharedStore.shared.settings = settings
        }
    }

    private init() {
        settings = SharedStore.shared.settings
    }
}
