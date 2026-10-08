//
//  WidgetCustomizationView.swift
//  mochimix
//

import PhotosUI
import SwiftUI
import WidgetKit

/// The widget's look (font + background), pushed from Settings rather than
/// its own main tab. A live preview at the top renders the real widget view
/// (shared with the widget extension -- see WidgetContentView.swift) with
/// the current selections and cached items, so changes show up instantly.
struct WidgetCustomizationView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject private var auth = SpotifyAuthService.shared
    @Environment(\.dismiss) private var dismiss

    /// What the widget is currently showing. Only font/background change on
    /// this page, so reading it once on appear is enough.
    @State private var display = SharedStore.shared.loadWidgetItems()

    @State private var pickedPhoto: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var isSavingPhoto = false
    @State private var photoError: String?
    /// Bumped whenever a new photo is saved, to redraw views showing it.
    @State private var customPhotoVersion = 0

    private static let widgetKind = "mochimix_widget"

    var body: some View {
        // Only the options panel scrolls; the preview stays put above it.
        VStack(spacing: 0) {
            preview
                .padding(.top, 36)
                .padding(.bottom, 28)

            optionsPanel
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PageTitle(title: "Widget", onBack: { dismiss() })
        }
        .background(AppTheme.background)
        // PageTitle draws its own back button inside the shared top bar.
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            display = SharedStore.shared.loadWidgetItems()
        }
        .onChange(of: settingsStore.settings.font) { _, _ in
            WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        }
        .onChange(of: settingsStore.settings.backgroundID) { _, _ in
            WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task { await savePickedPhoto(item) }
        }
        .alert("Photo not added", isPresented: Binding(
            get: { photoError != nil },
            set: { if !$0 { photoError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoError ?? "")
        }
    }

    // MARK: - Preview

    private var preview: some View {
        WidgetPreview(entry: SimpleEntry(
            date: .now,
            display: display,
            settings: settingsStore.settings,
            isLoggedIn: auth.isLoggedIn,
            lastFetchErrorMessage: nil
        ))
        .id(customPhotoVersion)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Photo upload

    /// Deletes the custom photo; if it was the selected background, falls
    /// back to the first bundled one.
    private func removeCustomPhoto() {
        CustomBackground.remove()
        customPhotoVersion += 1
        if settingsStore.settings.backgroundID == CustomBackground.id {
            settingsStore.settings.backgroundID = BackgroundManifest.all.first?.id
                ?? BackgroundManifest.fallback[0].id
        }
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }

    /// Saves the picked photo as the custom background and selects it.
    private func savePickedPhoto(_ item: PhotosPickerItem) async {
        isSavingPhoto = true
        defer {
            isSavingPhoto = false
            pickedPhoto = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            try CustomBackground.save(data)
            customPhotoVersion += 1
            settingsStore.settings.backgroundID = CustomBackground.id
            // The id may not have changed (replacing an existing photo), so
            // the onChange below won't fire -- reload explicitly.
            WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
        } catch {
            photoError = "Couldn't use that photo. Try a different one."
        }
    }

    /// The one slot for the user's own photo, always first in the row:
    /// "Upload" until a photo is added, then the photo itself (badged so
    /// it reads as theirs). Tapping it then selects it; long-press offers
    /// Replace / Remove.
    @ViewBuilder
    private var customPhotoTile: some View {
        if let custom = CustomBackground.option {
            CustomPhotoBox(
                background: custom,
                isSelected: custom.id == settingsStore.settings.backgroundID,
                isLoading: isSavingPhoto,
                action: { settingsStore.settings.backgroundID = custom.id }
            )
            // A replaced photo keeps the same id, so force a redraw.
            .id(customPhotoVersion)
            .contextMenu {
                Button("Replace Photo", systemImage: "photo.badge.plus") {
                    isPhotoPickerPresented = true
                }
                Button("Remove Photo", systemImage: "trash", role: .destructive) {
                    removeCustomPhoto()
                }
            }
        } else {
            Button {
                isPhotoPickerPresented = true
            } label: {
                UploadPhotoBox(isLoading: isSavingPhoto)
            }
            .buttonStyle(.plain)
            .disabled(isSavingPhoto)
        }
    }

    // MARK: - Options panel
    //
    // A sheet-like panel, rounded only at the top, filling the rest of the
    // screen. It's `cardBackground` (the tab bar's color, so the two read as
    // one surface); each section inside sits in a box of the darker page
    // background. The panel scrolls on its own -- always bouncy, even with
    // nothing more to show -- and clips its content to its rounded top.

    private static let panelShape = UnevenRoundedRectangle(
        topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous
    )

    private var optionsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                optionSection("Widget Font") {
                    ForEach(WidgetFontChoice.allCases) { font in
                        FontPreviewBox(
                            font: font,
                            isSelected: font == settingsStore.settings.font,
                            action: { settingsStore.settings.font = font }
                        )
                    }
                }

                optionSection("Widget Background") {
                    customPhotoTile

                    // Loaded from Backgrounds/backgrounds.json -- add a new
                    // option there (plus its PNG) and it shows up here
                    // automatically, no code changes needed.
                    ForEach(BackgroundManifest.all) { background in
                        BackgroundPreviewBox(
                            background: background,
                            isSelected: background.id == settingsStore.settings.backgroundID,
                            action: { settingsStore.settings.backgroundID = background.id }
                        )
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.always)
        .background {
            Self.panelShape
                .fill(AppTheme.cardBackground)
                .shadow(color: .black.opacity(0.12), radius: 12, y: -2)
        }
        .clipShape(Self.panelShape)
    }

    /// A heading plus a horizontally scrolling row of options, in a rounded
    /// box of the page background color.
    private func optionSection<Options: View>(
        _ title: String,
        @ViewBuilder options: () -> Options
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
                .foregroundStyle(AppTheme.primaryText)

            PersistentScrollBarRow(content: options())
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.background)
            }
        }
    }
}

/// A horizontally scrolling row with its own always-visible scroll bar
/// underneath. The system indicator can't be pinned on -- it fades out
/// after scrolling -- so it's hidden and this draws one that tracks the
/// scroll position instead.
private struct PersistentScrollBarRow<Content: View>: View {
    let content: Content

    @State private var offset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0

    private struct Metrics: Equatable {
        var offset: CGFloat
        var contentWidth: CGFloat
        var visibleWidth: CGFloat
    }

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    content
                }
                // Room for the selection checkmark at the top-right.
                .padding(.vertical, 6)
            }
            .onScrollGeometryChange(for: Metrics.self) { geometry in
                Metrics(
                    offset: geometry.contentOffset.x + geometry.contentInsets.leading,
                    contentWidth: geometry.contentSize.width,
                    visibleWidth: geometry.containerSize.width
                )
            } action: { _, metrics in
                offset = metrics.offset
                contentWidth = metrics.contentWidth
                visibleWidth = metrics.visibleWidth
            }

            if contentWidth > visibleWidth + 1 {
                scrollBar
            }
        }
    }

    private var scrollBar: some View {
        GeometryReader { track in
            // A fixed share of the track, not sized to how much is visible,
            // so every row's bar looks the same however many options it has.
            let thumbWidth = track.size.width * 0.3
            let maxOffset = contentWidth - visibleWidth
            let progress = min(max(offset / maxOffset, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.secondaryText.opacity(0.15))
                Capsule()
                    .fill(AppTheme.secondaryText.opacity(0.6))
                    .frame(width: thumbWidth)
                    .offset(x: (track.size.width - thumbWidth) * progress)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// The real widget view at systemMedium size, on its chosen background.
/// Non-interactive: the widget's own Links would otherwise open Spotify.
private struct WidgetPreview: View {
    let entry: SimpleEntry

    // iPhone systemMedium widget size (points).
    private let size = CGSize(width: 338, height: 158)

    var body: some View {
        mochimix_widgetEntryView(entry: entry)
            .frame(width: size.width, height: size.height)
            .background {
                BackgroundImage(option: BackgroundManifest.resolve(id: entry.settings.backgroundID))
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Widget preview")
            .animation(.easeInOut(duration: 0.2), value: entry.settings)
    }
}

private struct FontPreviewBox: View {
    let font: WidgetFontChoice
    let isSelected: Bool
    let action: () -> Void

    private var previewYOffset: CGFloat {
        let name = font.displayName.lowercased()

        if name.contains("avenir") || name.contains("snell") || name.contains("cursive") || name.contains("academy") {
            return 5
        }

        return 0
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        Text("Aa")
                            .font(font.font(.title))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .fixedSize(horizontal: true, vertical: true)
                            .offset(y: previewYOffset)
                    }
                    .frame(width: 72, height: 42, alignment: .bottom)

                    // Deliberately the *default* system font, not `font`
                    // itself -- so the label underneath stays readable no
                    // matter how unusual the previewed font looks.
                    Text(font.displayName)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: 64, height: 16, alignment: .top)
                }
                .frame(width: 72, height: 72, alignment: .center)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.iconPlaceholderBackground)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.system(size: 16))
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// The user's uploaded photo as a background tile: like any other tile,
/// plus a small photo badge in the bottom-left marking it as theirs (the
/// selected checkmark keeps the top-right). Shows a spinner while a
/// replacement is being saved.
private struct CustomPhotoBox: View {
    let background: BackgroundOption
    let isSelected: Bool
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        BackgroundPreviewBox(background: background, isSelected: isSelected, action: action)
            .overlay(alignment: .bottomLeading) {
                Image(systemName: "photo.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.black.opacity(0.55)))
                    .padding(5)
                    .allowsHitTesting(false)
            }
            .overlay {
                if isLoading {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.black.opacity(0.4))
                        .overlay { ProgressView().tint(.white) }
                }
            }
            .accessibilityLabel("Your photo")
            .accessibilityHint("Long-press to replace or remove")
    }
}

/// The first tile in the Background row until a photo is uploaded: opens
/// the photo picker.
private struct UploadPhotoBox: View {
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 4) {
            if isLoading {
                ProgressView()
            } else {
                Image(systemName: "photo.badge.plus")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            Text("Upload")
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(width: 72, height: 72)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.iconPlaceholderBackground)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("Upload a photo for the widget background")
    }
}

private struct BackgroundPreviewBox: View {
    let background: BackgroundOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                BackgroundImage(option: background)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                    }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.system(size: 16))
                        .padding(4)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        WidgetCustomizationView(settingsStore: .shared)
    }
}
