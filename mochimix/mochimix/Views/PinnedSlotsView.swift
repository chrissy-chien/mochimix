//
//  PinnedSlotsView.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The 5 pinned-item slots, shown under the compact recent-items list
/// whenever widget mode is Hybrid or Pinned Items. Tapping an empty slot
/// opens Spotify search (PinSearchView) to pick something to pin; a
/// long-press on a filled slot offers move-left/move-right/remove, and a
/// small "x" badge offers quick removal without needing to discover the
/// long-press menu.
struct PinnedSlotsView: View {
    @ObservedObject var pinStore: PinStore
    let mode: WidgetMode

    private struct SlotSelection: Identifiable {
        let index: Int
        var id: Int { index }
    }
    @State private var activeSearch: SlotSelection?
    @State private var draggingIndex: Int?
    @State private var draggingItemID: String?
    @Namespace private var pinnedSlotNamespace

    /// In Hybrid mode only 4 slots feed the widget -- the would-be 5th
    /// tile is reserved for the most recent source item instead -- so the
    /// 5th slot (index 4) is disabled here rather than usable.
    private func isEnabled(_ index: Int) -> Bool {
        mode == .pinned || index < 4
    }

    private func pinTargetIndex(forTappedEmptySlot tappedIndex: Int) -> Int {
        let visibleSlotCount = mode == .hybrid ? 4 : SpotifyConfig.pinnedSlotCount

        for slot in 0..<min(visibleSlotCount, SpotifyConfig.pinnedSlotCount) {
            if pinStore.item(atSlot: slot) == nil {
                return slot
            }
        }

        return tappedIndex
    }

    private func removeAndShiftLeft(from index: Int) {
        let visibleSlotCount = mode == .hybrid ? 4 : SpotifyConfig.pinnedSlotCount

        withAnimation(.easeInOut(duration: 0.2)) {
            pinStore.unpin(atSlot: index)

            for slot in (index + 1)..<visibleSlotCount {
                if pinStore.item(atSlot: slot) != nil {
                    pinStore.moveLeft(slot)
                }
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<SpotifyConfig.pinnedSlotCount, id: \.self) { index in
                let item = isEnabled(index) ? pinStore.item(atSlot: index) : nil

                PinnedSlotCell(
                    item: item,
                    isEnabled: isEnabled(index),
                    namespace: pinnedSlotNamespace,
                    onTapEmpty: { activeSearch = SlotSelection(index: pinTargetIndex(forTappedEmptySlot: index)) },
                    onRemove: { removeAndShiftLeft(from: index) },
                    onDragItem: {
                        guard let item, isEnabled(index) else { return NSItemProvider() }
                        draggingIndex = index
                        draggingItemID = item.id
                        return NSItemProvider(object: item.id as NSString)
                    }
                )
                .onDrop(
                    of: [UTType.text],
                    delegate: PinnedSlotDropDelegate(
                        destinationIndex: index,
                        isEnabled: isEnabled(index) && item != nil,
                        pinStore: pinStore,
                        draggingIndex: $draggingIndex,
                        draggingItemID: $draggingItemID,
                        clearDraggingState: clearDraggingState
                    )
                )
            }
        }
        .frame(maxWidth: .infinity)
        .sheet(item: $activeSearch) { selection in
            PinSearchView(slotIndex: selection.index, pinStore: pinStore)
        }
        .onDisappear {
            draggingIndex = nil
            draggingItemID = nil
        }
    }

    private func clearDraggingState() {
        draggingIndex = nil
        draggingItemID = nil
    }
}

private struct PinnedSlotDropDelegate: DropDelegate {
    let destinationIndex: Int
    let isEnabled: Bool
    let pinStore: PinStore
    @Binding var draggingIndex: Int?
    @Binding var draggingItemID: String?
    let clearDraggingState: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && draggingIndex != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard isEnabled,
              let draggedID = draggingItemID,
              let sourceIndex = currentIndex(for: draggedID),
              sourceIndex != destinationIndex else { return }

        withAnimation(.easeInOut(duration: 0.32)) {
            movePinnedItem(from: sourceIndex, to: destinationIndex)
            draggingIndex = destinationIndex
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        clearDraggingState()
        return true
    }

    func dropExited(info: DropInfo) { }

    private func currentIndex(for itemID: String) -> Int? {
        for slot in 0..<SpotifyConfig.pinnedSlotCount {
            if pinStore.item(atSlot: slot)?.id == itemID {
                return slot
            }
        }
        return nil
    }

    private func movePinnedItem(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex else { return }

        if sourceIndex < destinationIndex {
            for slot in sourceIndex..<destinationIndex {
                pinStore.moveRight(slot)
            }
        } else {
            for slot in stride(from: sourceIndex, to: destinationIndex, by: -1) {
                pinStore.moveLeft(slot)
            }
        }
    }
}

private struct PinnedSlotCell: View {
    let item: MochiMixItem?
    let isEnabled: Bool
    let namespace: Namespace.ID
    let onTapEmpty: () -> Void
    let onRemove: () -> Void
    let onDragItem: () -> NSItemProvider

    private let cornerRadius: CGFloat = 14
    private let size: CGFloat = 60

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .opacity(isEnabled ? 1 : 0.5)
                .grayscale(isEnabled ? 0 : 1)

            if item != nil, isEnabled {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .font(.system(size: 17))
                }
                .buttonStyle(.plain)
                .offset(x: 3, y: -3)
            }
        }
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        if let item {
            filledSlot(item)
        } else {
            emptySlot
        }
    }

    private func filledSlot(_ item: MochiMixItem) -> some View {
        let shape: AnyShape = item.type.isCircularArtwork
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

        return VStack(spacing: 4) {
            artwork(for: item)
                .frame(width: size, height: size)
                .background {
                    placeholder(for: item)
                }
                .clipShape(shape)
                .contentShape(shape)
                .contentShape(.dragPreview, shape)
                .onDrag {
                    onDragItem()
                } preview: {
                    DragPreviewArtwork(item: item)
                }

            // Title only -- no subtitle inside a filled slot, per design.
            Text(item.name)
                .font(.caption2)
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .frame(width: size)
        }
        .matchedGeometryEffect(id: item.id, in: namespace)
    }

    private var emptySlot: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(AppTheme.iconPlaceholderBackground)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: isEnabled ? "plus" : "music.note.list")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .contentShape(Rectangle())
            .allowsHitTesting(isEnabled)
            .onTapGesture {
                onTapEmpty()
            }
    }

    @ViewBuilder
    private func artwork(for item: MochiMixItem) -> some View {
        if let url = item.artworkURL {
            PinnedArtworkImageView(
                url: url,
                placeholderSymbolName: symbolName(for: item.type)
            )
        } else {
            placeholder(for: item)
        }
    }

    private func placeholder(for item: MochiMixItem) -> some View {
        Rectangle()
            .fill(AppTheme.iconPlaceholderBackground)
            .overlay {
                Image(systemName: symbolName(for: item.type))
                    .foregroundStyle(AppTheme.secondaryText)
            }
    }

    private func symbolName(for type: MochiMixItem.ItemType) -> String {
        switch type {
        case .playlist: return "music.note.list"
        case .album: return "square.stack"
        case .artist: return "person.crop.circle"
        case .track: return "music.note"
        }
    }
}

private struct DragPreviewArtwork: View {
    let item: MochiMixItem

    private let size: CGFloat = 64

    var body: some View {
        ZStack {
            if let url = item.artworkURL,
               let image = PinnedArtworkImageView.cachedImage(for: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .contentShape(shape)
        .contentShape(.dragPreview, shape)
        .background(Color.clear)
        .compositingGroup()
    }

    private var shape: AnyShape {
        item.type.isCircularArtwork
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var placeholder: some View {
        Rectangle()
            .fill(AppTheme.iconPlaceholderBackground)
            .overlay {
                Image(systemName: symbolName(for: item.type))
                    .foregroundStyle(AppTheme.secondaryText)
            }
    }

    private func symbolName(for type: MochiMixItem.ItemType) -> String {
        switch type {
        case .playlist: return "music.note.list"
        case .album: return "square.stack"
        case .artist: return "person.crop.circle"
        case .track: return "music.note"
        }
    }
}

private struct PinnedArtworkImageView: View {
    let url: URL
    let placeholderSymbolName: String

    @State private var image: UIImage?
    private static let imageCache = NSCache<NSURL, UIImage>()

    var body: some View {
        ZStack {
            Rectangle()
                .fill(AppTheme.iconPlaceholderBackground)
                .overlay {
                    Image(systemName: placeholderSymbolName)
                        .foregroundStyle(AppTheme.secondaryText)
                }

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            if let cached = Self.cachedImage(for: url) {
                setImage(cached, animated: false)
            } else {
                await loadImage()
            }
        }
    }

    @MainActor
    private func setImage(_ newImage: UIImage?, animated: Bool = true) {
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                image = newImage
            }
        } else {
            image = newImage
        }
    }

    static func cachedImage(for url: URL) -> UIImage? {
        imageCache.object(forKey: url as NSURL)
    }

    private func loadImage() async {
        await MainActor.run {
            setImage(nil, animated: false)
        }

        do {
            let request = URLRequest(
                url: url,
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: 20
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let loadedImage = UIImage(data: data) else {
                return
            }

            Self.imageCache.setObject(loadedImage, forKey: url as NSURL)
            await MainActor.run {
                setImage(loadedImage)
            }
        } catch {
            #if DEBUG
            debugLog("Pinned artwork failed to load for \(url.absoluteString): \(error)")
            #endif
        }
    }
}

private struct CachedPinnedArtworkImageView: View {
    let url: URL
    let placeholderSymbolName: String

    var body: some View {
        if let image = PinnedArtworkImageView.cachedImage(for: url) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(AppTheme.iconPlaceholderBackground)
                .overlay {
                    Image(systemName: placeholderSymbolName)
                        .foregroundStyle(AppTheme.secondaryText)
                }
        }
    }
}

#Preview {
    PinnedSlotsView(pinStore: .shared, mode: .hybrid)
        .padding()
}

