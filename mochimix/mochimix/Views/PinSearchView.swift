//
//  PinSearchView.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import SwiftUI

/// Presented as a sheet when the user taps an empty pinned slot. Lets them
/// search Spotify for a playlist, album, or artist (never tracks) and pin
/// it into that specific slot.
struct PinSearchView: View {
    let slotIndex: Int
    @ObservedObject var pinStore: PinStore
    @StateObject private var viewModel = PinSearchViewModel()
    @Environment(\.dismiss) private var dismiss

    /// Guards against selecting twice (e.g. a double-tap landing on the
    /// same row while the sheet is mid-dismiss) -- without this, a fast
    /// second tap could fire `pinStore.pin` again before the sheet finishes
    /// closing. This is the one path both recommendation taps and search
    /// result taps go through, so the behavior is identical either way:
    /// pin into the selected slot, then dismiss.
    @State private var hasSelected = false
    @State private var hasStartedRecommendationLoad = false

    private var displayedRecommendations: [MochiMixItem] {
        Array(viewModel.recommendations.prefix(SpotifyConfig.displayItemCount))
    }

    private func select(_ item: MochiMixItem) {
        guard !hasSelected else { return }
        hasSelected = true
        pinStore.pin(item, atSlot: slotIndex)
        dismiss()
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.secondaryText)

            TextField("Playlists, albums, artists", text: $viewModel.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    Task {
                        await viewModel.search()
                    }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.cardBackground)
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar

                Group {
                if viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if displayedRecommendations.isEmpty {
                        ContentUnavailableView(
                            "Search Spotify",
                            systemImage: "magnifyingglass",
                            description: Text("Find a playlist, album, or artist to pin.")
                        )
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Recently Played")
                                    .font(.headline)
                                    .foregroundStyle(AppTheme.primaryText)

                                VStack(spacing: 0) {
                                    ForEach(displayedRecommendations) { item in
                                        Button {
                                            select(item)
                                        } label: {
                                            SearchResultRow(item: item)
                                        }
                                        .buttonStyle(.plain)

                                        if item.id != displayedRecommendations.last?.id {
                                            Rectangle()
                                                .fill(AppTheme.divider)
                                                .frame(height: 1)
                                                .padding(.leading, 60)
                                                .padding(.vertical, 6)
                                        }
                                    }

                                }
                                .sectionCardBackground()
                            }
                            .padding()
                        }
                    }
                } else if viewModel.isLoading {
                    ProgressView("Searching…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = viewModel.errorMessage {
                    ContentUnavailableView(
                        "Search Failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if viewModel.results.isEmpty {
                    ContentUnavailableView.search(text: viewModel.query)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(spacing: 0) {
                                ForEach(viewModel.results) { item in
                                    Button {
                                        select(item)
                                    } label: {
                                        SearchResultRow(item: item)
                                    }
                                    .buttonStyle(.plain)

                                    if item.id != viewModel.results.last?.id {
                                        Rectangle()
                                            .fill(AppTheme.divider)
                                            .frame(height: 1)
                                            .padding(.leading, 60)
                                            .padding(.vertical, 6)
                                    }
                                }
                            }
                            .sectionCardBackground()
                        }
                        .padding()
                    }
                }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle("Pin an Item")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: viewModel.query) {
                let trimmedQuery = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedQuery.isEmpty else { return }

                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                await viewModel.search()
            }
            .task {
                guard !hasStartedRecommendationLoad else { return }
                hasStartedRecommendationLoad = true

                let trimmedQuery = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedQuery.isEmpty else { return }

                // Recommendations should be read from the already-saved recent
                // item cache, so loading them immediately should not block the
                // keyboard or call Spotify.
                await viewModel.loadRecommendationsIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct SearchResultRow: View {
    let item: MochiMixItem

    var body: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: 48, height: 48)
                .clipShape(artworkShape)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                Text(captionText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// Combines subtitle + item type so both are visible in one compact
    /// line, e.g. "Taylor Swift · Album" or just "Playlist" when there's
    /// no subtitle.
    private var captionText: String {
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            return "\(subtitle) · \(typeLabel)"
        }
        return typeLabel
    }

    private var typeLabel: String {
        switch item.type {
        case .playlist: return "Playlist"
        case .album: return "Album"
        case .artist: return "Artist"
        case .track: return "Track"
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = item.artworkURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    /// Circle for artists, rounded-corner square for everything else.
    private var artworkShape: AnyShape {
        item.type.isCircularArtwork
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var placeholder: some View {
        artworkShape
            .fill(AppTheme.iconPlaceholderBackground)
            .overlay {
                Image(systemName: typeSymbolName)
                    .foregroundStyle(AppTheme.secondaryText)
            }
    }

    private var typeSymbolName: String {
        switch item.type {
        case .playlist: return "music.note.list"
        case .album: return "square.stack"
        case .artist: return "person.crop.circle"
        case .track: return "music.note"
        }
    }
}

private extension View {
    func sectionCardBackground() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.cardBackground)
            }
    }
}
