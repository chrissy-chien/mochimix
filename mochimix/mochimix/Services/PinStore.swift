//
//  PinStore.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import Foundation
import Combine

/// Manages the user's pinned items as 5 **ordered slots** (see
/// `PinnedSlots`), used by the "Pinned Items" and "Hybrid" widget modes.
/// Backed by SharedStore (so the data lives in the App Group container) --
/// though only the app itself reads/writes slots directly; the widget
/// never sees them raw, only the final computed display data that
/// WidgetDataProvider writes for it.
///
/// Every mutation immediately recomputes and pushes the widget's display
/// data (via `WidgetDataProvider.refreshWidgetDisplayOnly()`), so pinning,
/// unpinning, and reordering all show up on the Home Screen widget right
/// away without waiting for the next network refresh.
@MainActor
final class PinStore: ObservableObject {
    static let shared = PinStore()

    @Published private(set) var slots: PinnedSlots

    private init() {
        slots = SharedStore.shared.pinnedSlots
    }

    func item(atSlot index: Int) -> MochiMixItem? {
        guard slots.slots.indices.contains(index) else { return nil }
        return slots.slots[index]
    }

    func isPinned(_ item: MochiMixItem) -> Bool {
        slots.slots.contains { $0?.id == item.id }
    }

    /// Pins `item` into the given slot. If that exact item (same
    /// `itemType` + Spotify id) is already pinned in a *different* slot,
    /// it's moved here instead of being duplicated -- the same Spotify
    /// item can never occupy two slots at once. This also makes repeated
    /// calls with the same item/slot (e.g. a double-tap on a search
    /// result) harmless: the second call just re-pins the same item into
    /// the same slot, a no-op in effect.
    func pin(_ item: MochiMixItem, atSlot index: Int) {
        guard slots.slots.indices.contains(index) else { return }

        if let existingIndex = slots.slots.firstIndex(where: { $0?.id == item.id && $0?.type == item.type }) {
            guard existingIndex != index else {
                slots.slots[index] = item
                persist()
                return
            }

            slots.slots.remove(at: existingIndex)
            let adjustedIndex = existingIndex < index ? index - 1 : index
            slots.slots.insert(item, at: adjustedIndex)
            persist()
            return
        }

        slots.slots[index] = item
        persist()
    }

    func unpin(atSlot index: Int) {
        guard slots.slots.indices.contains(index) else { return }
        slots.slots[index] = nil
        persist()
    }

    /// Swaps a slot with its left/right neighbor. Used by the pinned-slot
    /// row's long-press "Move Left"/"Move Right" actions (the simple,
    /// reliable fallback to full drag-and-drop reordering).
    func moveLeft(_ index: Int) {
        swapSlots(index, index - 1)
    }

    func moveRight(_ index: Int) {
        swapSlots(index, index + 1)
    }

    private func swapSlots(_ a: Int, _ b: Int) {
        guard slots.slots.indices.contains(a), slots.slots.indices.contains(b) else { return }
        slots.slots.swapAt(a, b)
        persist()
    }

    private func persist() {
        SharedStore.shared.pinnedSlots = slots
        Task { await WidgetDataProvider.shared.refreshWidgetDisplayOnly() }
    }
}
