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

    var body: some View {
        Group {
            if let uiImage = BundledResource.image(named: option.image) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
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
