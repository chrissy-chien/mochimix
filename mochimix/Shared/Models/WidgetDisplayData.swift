//
//  WidgetDisplayData.swift
//  Shared (used by both the mochimix app and the mochimix-widget extension)
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation

/// The final, mode-applied data the widget renders: one optional "top"
/// item (the large tile) and exactly 4 optional "tile" items (the small
/// row below). Both are optional so an empty slot in Hybrid/Pinned mode
/// can be represented explicitly -- as opposed to a plain `[MochiMixItem]`,
/// which can only express "how many items" and can't say *which* position
/// is empty.
struct WidgetDisplayData: Codable, Equatable {
    var topItem: MochiMixItem?
    /// Always exactly 4 elements.
    var tileItems: [MochiMixItem?]

    init(topItem: MochiMixItem?, tileItems: [MochiMixItem?]) {
        self.topItem = topItem
        if tileItems.count == 4 {
            self.tileItems = tileItems
        } else if tileItems.count < 4 {
            self.tileItems = tileItems + Array(repeating: nil, count: 4 - tileItems.count)
        } else {
            self.tileItems = Array(tileItems.prefix(4))
        }
    }

    static let empty = WidgetDisplayData(topItem: nil, tileItems: Array(repeating: nil, count: 4))
}
