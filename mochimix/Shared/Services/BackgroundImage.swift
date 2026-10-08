//
//  BackgroundImage.swift
//  Shared (used by both the mochimix app and the mochimix-widget extension)
//
//  Created by Chrissy Chien on 7/8/26.
//

import SwiftUI

/// Renders a chosen background: the real bundled PNG if one's been added
/// for it, or a muted placeholder (soft gradient + photo icon) if that PNG
/// is still missing. Used identically by the Settings preview swatches
/// and the widget's `containerBackground`, so both look consistent and
/// both degrade the same way when an asset hasn't been provided yet.
struct BackgroundImage: View {
    let option: BackgroundOption
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if option.id == CustomBackground.id, let uiImage = CustomBackground.image() {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .overlay { customPhotoTreatment }
            } else if let uiImage = BundledResource.image(named: option.image) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
    }

    /// The bundled backgrounds have this baked into their PNGs: the bottom
    /// half darkened by 25% black, and a 1px divider across the middle --
    /// #E0E0E0 on dark backgrounds, #222222 on light ones. An uploaded photo
    /// gets the same look drawn on top, using its measured brightness (the
    /// same light/dark call that picks the widget's text color).
    private var customPhotoTreatment: some View {
        VStack(spacing: 0) {
            Color.clear
            Color.black.opacity(0.25)
        }
        .overlay {
            Rectangle()
                .fill(option.color == .white
                      ? Color(red: 0xE0 / 255, green: 0xE0 / 255, blue: 0xE0 / 255)
                      : Color(red: 0x22 / 255, green: 0x22 / 255, blue: 0x22 / 255))
                .frame(height: 1 / displayScale)
        }
        .allowsHitTesting(false)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.55).opacity(0.35), Color(white: 0.3).opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }
}
