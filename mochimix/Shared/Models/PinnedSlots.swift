//
//  PinnedSlots.swift
//  Shared (used by both the mochimix app and the mochimix-widget extension)
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation

/// The user's pinned items, stored as a fixed number of **ordered slots**
/// rather than a plain array. Each slot either holds a `MochiMixItem` or is
/// `nil` (empty). This is deliberately not just "an array of pinned items"
/// because slot *position* matters: the pinned-slots editor needs to know
/// exactly which of the 5 positions is empty (to show a "+" there), and
/// Hybrid mode needs the bottom 4 tiles to keep their positions even when
/// some are empty, rather than the list silently compacting.
struct PinnedSlots: Codable, Equatable {
    /// Always exactly `SpotifyConfig.pinnedSlotCount` elements.
    var slots: [MochiMixItem?]

    init(slots: [MochiMixItem?] = []) {
        self.slots = Self.normalized(slots)
    }

    /// Pads with `nil` or truncates so `slots` is always exactly the
    /// expected count, no matter what was decoded/passed in.
    private static func normalized(_ slots: [MochiMixItem?]) -> [MochiMixItem?] {
        let count = SpotifyConfig.pinnedSlotCount
        if slots.count == count {
            return slots
        } else if slots.count < count {
            return slots + Array(repeating: nil, count: count - slots.count)
        } else {
            return Array(slots.prefix(count))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode([MochiMixItem?].self)
        self.slots = Self.normalized(decoded)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(slots)
    }

    static let empty = PinnedSlots()
}
