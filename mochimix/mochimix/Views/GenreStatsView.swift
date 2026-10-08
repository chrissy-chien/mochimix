//
//  GenreStatsView.swift
//  mochimix
//

import SwiftUI

/// Shows a genre breakdown of the logged-in user's Spotify "top artists"
/// (GET /me/top/artists) across Spotify's three affinity windows, as 3
/// swipeable sub-pages -- Tags (flat, every raw genre tag), Genres (major
/// genres summing to 100%, each expanding into its own subgenre split),
/// and Artists (the full ranked list). Every genre is colored by its
/// umbrella family (see `ParentGenre`), not its own raw tag -- subgenres
/// under the same family (dubstep, house) render in the same color.
///
/// `isActive` is threaded in from `ContentView` (true only while this is
/// the currently-selected main tab) -- used to close any open dropdown
/// and to drive the >2-minute scroll reset (`ScrollResettingPage`) when
/// the user swipes/taps away and back.
struct GenreStatsView: View {
    let isActive: Bool

    @ObservedObject private var store = GenreStatsStore.shared
    @State private var selectedRange: GenreStatsStore.TimeRange = .mediumTerm
    @State private var chartMode: ChartMode = .tags
    @State private var isRefreshing = false

    // Lifted out of each row (rather than each row owning its own local
    // `@State isExpanded`) specifically so a tab change can close
    // whatever's open -- see the `onChange` handlers below.
    @State private var expandedTagGenre: String?
    @State private var expandedMajorGenre: ParentGenre?

    // Bar "grow in" animation (Tags and Genres pages). Every bar is drawn at
    // min(its fraction, its page's reveal), and only the reveal animates
    // (linearly, at a fixed speed) -- so all bars grow at the same rate and
    // longer ones finish later. 1 = fully drawn. Each page has its own
    // reveal so the page sliding out keeps its bars while the new one grows.
    //
    // Replays on every time-range change and every switch to a page with
    // bars; returning to the Stats tab replays only after being away for
    // longer than `barReplayAfter`.
    @State private var barReveal: [ChartMode: Double] = [:]
    /// Bumped per run so a superseded run's delayed start / completion
    /// can't stomp on a newer one.
    @State private var barAnimationRun = 0
    /// When the Stats tab was last left; nil until it's first been shown.
    @State private var lastSeenAt: Date?
    /// Set when an animation was due but there was no data to animate yet.
    @State private var barAnimationPending = false

    /// Fraction of the full bar width revealed per second.
    private static let barRevealSpeed = 1.2
    /// Away from the tab for longer than this replays the animation.
    private static let barReplayAfter: TimeInterval = 120

    private func reveal(for mode: ChartMode) -> Double {
        barReveal[mode] ?? 1
    }

    enum ChartMode: Hashable {
        case tags, genres, artists
    }

    private var shares: [GenreStatsStore.GenreShare] {
        store.breakdowns[selectedRange] ?? []
    }

    private var artists: [SpotifyArtist] {
        store.topArtistsByRange[selectedRange] ?? []
    }

    private var emptyMessage: String {
        "Spotify needs more listening history in this time range before it can compute your top artists."
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // `.page` style is what gives swiping between Tags/Genres/
                // Artists its native, finger-tracking slide animation --
                // the floating toggle below sets the same `chartMode`
                // binding, so tapping it and swiping stay in sync.
                TabView(selection: $chartMode) {
                    ScrollResettingPage(isActive: isActive && chartMode == .tags, onRefresh: { await refresh(force: true) }) {
                        pageBody(isEmpty: shares.isEmpty, emptyTitle: "No genre data yet") {
                            VStack(spacing: 10) {
                                ForEach(shares) { share in
                                    GenreShareRow(share: share, range: selectedRange, barReveal: reveal(for: .tags), expandedGenre: $expandedTagGenre)
                                }
                            }
                            .padding()
                        }
                    }
                    .tag(ChartMode.tags)

                    ScrollResettingPage(isActive: isActive && chartMode == .genres, onRefresh: { await refresh(force: true) }) {
                        pageBody(isEmpty: shares.isEmpty, emptyTitle: "No genre data yet") {
                            MajorGenreSection(
                                shares: store.majorGenreBreakdown(in: selectedRange),
                                range: selectedRange,
                                barReveal: reveal(for: .genres),
                                expandedMajorGenre: $expandedMajorGenre
                            )
                            .padding()
                        }
                    }
                    .tag(ChartMode.genres)

                    ScrollResettingPage(isActive: isActive && chartMode == .artists, onRefresh: { await refresh(force: true) }) {
                        pageBody(isEmpty: artists.isEmpty, emptyTitle: "No artist data yet") {
                            ArtistRankingSection(artists: artists)
                                .padding()
                        }
                    }
                    .tag(ChartMode.artists)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // An inset (not a VStack row) so the charts scroll up
                // behind the header's translucent background.
                .safeAreaInset(edge: .top, spacing: 0) {
                    header
                }
            }
            .background(AppTheme.background)
            .safeAreaInset(edge: .bottom) {
                chartModeToggle
                    .padding(.bottom, 8)
            }
        }
        .task {
            await refresh(force: false)
        }
        // Changing sub-tabs (tap or swipe) closes whatever dropdown was
        // open on the tab being left.
        .onChange(of: chartMode) { _, mode in
            expandedTagGenre = nil
            expandedMajorGenre = nil
            requestBarAnimation(for: mode)
        }
        // So does switching time ranges -- an open dropdown's contents
        // belong to the range being left.
        .onChange(of: selectedRange) { _, _ in
            expandedTagGenre = nil
            expandedMajorGenre = nil
            requestBarAnimation(for: chartMode)
        }
        // Leaving the Stats tab entirely (main tab change) does the same.
        .onChange(of: isActive) { _, active in
            if active {
                if let lastSeenAt, Date().timeIntervalSince(lastSeenAt) <= Self.barReplayAfter {
                    return
                }
                requestBarAnimation(for: chartMode)
            } else {
                expandedTagGenre = nil
                expandedMajorGenre = nil
                lastSeenAt = Date()
            }
        }
        .onAppear {
            if isActive, lastSeenAt == nil { requestBarAnimation(for: chartMode) }
        }
        // First-ever load: the tab can be opened before any data exists.
        .onChange(of: shares.isEmpty) { _, isEmpty in
            if !isEmpty, barAnimationPending {
                requestBarAnimation(for: chartMode)
            }
        }
    }

    // MARK: - Bar animation

    /// Longest bar on a page -- the animation runs until it's fully drawn.
    private func longestBar(on mode: ChartMode) -> Double? {
        switch mode {
        case .tags: return shares.map(\.fraction).max()
        case .genres: return store.majorGenreBreakdown(in: selectedRange).map(\.fraction).max()
        case .artists: return nil
        }
    }

    private func requestBarAnimation(for mode: ChartMode) {
        guard mode != .artists else { return }
        guard let target = longestBar(on: mode), target > 0 else {
            // No data yet -- run once it arrives.
            barAnimationPending = true
            return
        }
        barAnimationPending = false
        barAnimationRun += 1
        let run = barAnimationRun

        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { barReveal[mode] = 0 }

        // Next run loop (not the same one) so the reset to 0 renders first.
        DispatchQueue.main.async {
            guard run == barAnimationRun else { return }
            withAnimation(.linear(duration: target / Self.barRevealSpeed)) {
                barReveal[mode] = target
            } completion: {
                // Bars are all full at `target`; 1 keeps later data (a
                // refresh) from being capped by it.
                if run == barAnimationRun { barReveal[mode] = 1 }
            }
        }
    }

    // MARK: - Header (fixed chrome above the swipeable pages)

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: "Stats", hasBackground: false)

            VStack(alignment: .leading, spacing: 20) {
                Picker("Time Range", selection: $selectedRange) {
                    ForEach(GenreStatsStore.TimeRange.allCases, id: \.self) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)

                familyLegend
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .topBarBackground()
    }

    /// Always shown (not just for Genres) since multiple bars/rows can
    /// share a color on purpose -- this is what explains why.
    private var familyLegend: some View {
        // `Grid` (not `LazyVGrid`) sizes each column to its widest cell
        // rather than splitting the full available width evenly -- a
        // `LazyVGrid` with flexible columns always stretches edge to
        // edge, so left-packed text of varying length (e.g. "Country"
        // vs. "Hip-Hop/Rap") leaves an uneven gap on the right of
        // shorter rows. `Grid` hugs its actual content width instead,
        // and `.frame(maxWidth: .infinity)` (default alignment: .center)
        // then centers that content-sized block, giving equal left/right
        // margins. 9 families / 3 columns divides evenly into exactly 3
        // rows -- if a family is ever added or removed, revisit this.
        let families = ParentGenre.allCases
        let columnsPerRow = 3
        return Grid(alignment: .leading, horizontalSpacing: 48, verticalSpacing: 6) {
            ForEach(0..<(families.count / columnsPerRow), id: \.self) { row in
                GridRow {
                    ForEach(0..<columnsPerRow, id: \.self) { column in
                        legendItem(families[row * columnsPerRow + column])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func legendItem(_ family: ParentGenre) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(family.color)
                .frame(width: 11, height: 11)
            Text(family.displayName)
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    // MARK: - Floating sub-tab toggle

    private var chartModeToggle: some View {
        HStack(spacing: 4) {
            toggleButton(mode: .tags, systemImage: "chart.bar.fill", label: "Tags")
            toggleButton(mode: .genres, systemImage: "list.bullet.indent", label: "Genres")
            toggleButton(mode: .artists, systemImage: "person.2.fill", label: "Artists")
        }
        .padding(6)
        .background {
            Capsule()
                .fill(AppTheme.cardBackground)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        }
    }

    private func toggleButton(mode: ChartMode, systemImage: String, label: String) -> some View {
        let isSelected = chartMode == mode
        return Button {
            withAnimation(.snappy(duration: 0.2)) { chartMode = mode }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(label)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isSelected ? .white : AppTheme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    Capsule().fill(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared loading/empty wrapper for each sub-page

    @ViewBuilder
    private func pageBody<Content: View>(isEmpty: Bool, emptyTitle: String, @ViewBuilder content: () -> Content) -> some View {
        if isRefreshing && isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                // getGenre (the primary genre source) showed no rate
                // limiting in testing, so resolving ~50-150 distinct
                // artists the first time is quick -- but every artist is
                // still cached indefinitely after that, so this is a
                // one-time cost regardless, not something that recurs.
                Text("Resolving genres\u{2026} this can take a moment the first time.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding()
        } else if isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(emptyTitle)
                    .font(.headline)
                    .foregroundStyle(AppTheme.primaryText)
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.cardBackground)
            }
            .padding()
        } else {
            content()
        }
    }

    private func refresh(force: Bool) async {
        isRefreshing = true
        await store.refreshAll(force: force)
        isRefreshing = false
    }
}

private struct MajorGenreSection: View {
    let shares: [GenreStatsStore.MajorGenreShare]
    let range: GenreStatsStore.TimeRange
    let barReveal: Double
    @Binding var expandedMajorGenre: ParentGenre?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Genres add up to 100% of your listening. Tap one to see how it splits into subgenres.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)

            VStack(spacing: 10) {
                ForEach(shares) { share in
                    MajorGenreRow(share: share, range: range, barReveal: barReveal, expandedMajorGenre: $expandedMajorGenre)
                }
            }
        }
    }
}

private struct MajorGenreRow: View {
    let share: GenreStatsStore.MajorGenreShare
    let range: GenreStatsStore.TimeRange
    /// See `GenreStatsView.barReveal`.
    let barReveal: Double
    @Binding var expandedMajorGenre: ParentGenre?

    @ObservedObject private var store = GenreStatsStore.shared

    private var isExpanded: Bool {
        expandedMajorGenre == share.parentGenre
    }

    private var percentText: String {
        let percent = share.fraction * 100
        return (percent < 10 ? String(format: "%.1f%%", percent) : String(format: "%.0f%%", percent))
    }

    // Computed fresh on expand -- synchronous, already-in-memory, no
    // network call, cheap enough to not need its own storage.
    private var subgenres: [GenreStatsStore.GenreShare] {
        store.subgenreBreakdown(for: share.parentGenre, in: range)
    }

    // A genre with no representation this period has nothing to expand
    // into -- still listed (as a 0% row), just not a dropdown.
    private var isExpandable: Bool {
        share.fraction > 0
    }

    private var header: some View {
        HStack {
            Text(share.parentGenre.displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.primaryText)
            if isExpandable {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            Spacer()
            Text(percentText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isExpandable {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        expandedMajorGenre = isExpanded ? nil : share.parentGenre
                    }
                } label: {
                    header
                }
                .buttonStyle(.plain)
            } else {
                header
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(AppTheme.iconPlaceholderBackground)
                RevealedBar(fraction: share.fraction, reveal: barReveal)
                    .fill(share.parentGenre.color)
            }
            .frame(height: 8)

            if isExpanded {
                Group {
                    if subgenres.isEmpty {
                        Text("No subgenres found for this genre in this time range.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(12)
                    } else {
                        // Same "one continuous background + thin dividers,
                        // no per-row gaps" treatment as the Tags tab's
                        // artist dropdown.
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(subgenres) { sub in
                                SubgenreRow(share: sub, parentGenre: share.parentGenre)

                                if sub.id != subgenres.last?.id {
                                    Rectangle()
                                        .fill(AppTheme.divider)
                                        .frame(height: 1)
                                        .padding(.leading, 34)
                                        .padding(.vertical, 9)
                                }
                            }
                        }
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(AppTheme.cardBackground)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.black.opacity(0.08))
                                }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.cardBackground)
        }
    }
}

private struct SubgenreRow: View {
    let share: GenreStatsStore.GenreShare
    let parentGenre: ParentGenre

    private var percentText: String {
        let percent = share.fraction * 100
        return (percent < 10 ? String(format: "%.1f%%", percent) : String(format: "%.0f%%", percent))
    }

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(parentGenre.color)
                .frame(width: 10, height: 10)

            Text(share.genre.capitalized)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)

            Spacer()

            Text(percentText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(AppTheme.secondaryText)
        }
    }
}

private struct GenreShareRow: View {
    let share: GenreStatsStore.GenreShare
    let range: GenreStatsStore.TimeRange
    /// See `GenreStatsView.tagBarReveal`.
    let barReveal: Double
    @Binding var expandedGenre: String?

    @ObservedObject private var store = GenreStatsStore.shared

    private var isExpanded: Bool {
        expandedGenre == share.genre
    }

    private var parentGenre: ParentGenre {
        ParentGenre.classify(share.genre)
    }

    private var percentText: String {
        let percent = share.fraction * 100
        return (percent < 10 ? String(format: "%.1f%%", percent) : String(format: "%.0f%%", percent))
    }

    // Computed fresh on expand rather than cached in state -- it's a
    // synchronous, already-in-memory filter (no network call), cheap
    // enough to not need debouncing/storage of its own.
    private var topArtists: [SpotifyArtist] {
        store.topArtists(forGenre: share.genre, in: range)
    }

    // Every artist here already comes from Spotify's top-50 list for
    // this range, so this is effectively always non-nil in practice --
    // kept optional anyway so the badge only ever shows a rank it can
    // actually back up.
    private func rank(for artist: SpotifyArtist) -> Int? {
        guard let index = store.topArtistsByRange[range]?.firstIndex(where: { $0.id == artist.id }) else {
            return nil
        }
        return index + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    expandedGenre = isExpanded ? nil : share.genre
                }
            } label: {
                HStack {
                    Text(share.genre.capitalized)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.primaryText)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Spacer()
                    Text(percentText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .buttonStyle(.plain)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(AppTheme.iconPlaceholderBackground)
                RevealedBar(fraction: share.fraction, reveal: barReveal)
                    .fill(parentGenre.color)
            }
            .frame(height: 8)

            if isExpanded {
                Group {
                    if topArtists.isEmpty {
                        Text("No artists found for this genre in this time range.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(12)
                    } else {
                        // One continuous background behind every row --
                        // no per-row boxes/gaps, a thin divider between
                        // rows instead (matches RecentItemsView's list).
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(topArtists, id: \.id) { artist in
                                GenreArtistRow(artist: artist, rank: rank(for: artist))

                                if artist.id != topArtists.last?.id {
                                    Rectangle()
                                        .fill(AppTheme.divider)
                                        .frame(height: 1)
                                        .padding(.leading, 62)
                                        .padding(.vertical, 6)
                                }
                            }
                        }
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(AppTheme.cardBackground)
                                .overlay {
                                    // "Slightly darker than the dropdown
                                    // box," relative to the parent card
                                    // rather than a fixed hex so it still
                                    // reads as darker in both light and
                                    // dark mode.
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.black.opacity(0.08))
                                }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.cardBackground)
        }
    }
}

/// A bar filled to `min(fraction, reveal)` of the width. Only `reveal` is
/// animatable, so animating it grows every bar at the same speed and
/// each one stops at its own fraction.
private struct RevealedBar: Shape {
    let fraction: Double
    var reveal: Double

    var animatableData: Double {
        get { reveal }
        set { reveal = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = rect.width * min(fraction, max(reveal, 0))
        let bar = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        return Path(roundedRect: bar, cornerRadius: min(4, width / 2), style: .continuous)
    }
}

/// The Artists sub-tab: every top artist for the selected time range,
/// ranked, each linking to its Spotify page -- unlike the Tags/Genres
/// dropdowns, this is always fully shown (no expand/collapse), since
/// it's already the page dedicated to artists rather than a nested
/// detail view.
private struct ArtistRankingSection: View {
    let artists: [SpotifyArtist]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your top \(artists.count) artists for this time range, ranked by Spotify affinity.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(artists.enumerated()), id: \.element.id) { index, artist in
                    GenreArtistRow(artist: artist, rank: index + 1)

                    if artist.id != artists.last?.id {
                        Rectangle()
                            .fill(AppTheme.divider)
                            .frame(height: 1)
                            .padding(.leading, 62)
                            .padding(.vertical, 6)
                    }
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.cardBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.08))
                    }
            }
        }
    }
}

private struct GenreArtistRow: View {
    let artist: SpotifyArtist
    let rank: Int?

    private var spotifyURL: URL {
        artist.externalUrls.spotify.flatMap(URL.init)
            ?? URL(string: "https://open.spotify.com/artist/\(artist.id)")!
    }

    private static let gold = LinearGradient(
        colors: [Color(red: 1.0, green: 0.86, blue: 0.4), Color(red: 0.82, green: 0.63, blue: 0.09)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    private static let silver = LinearGradient(
        colors: [Color(red: 0.88, green: 0.89, blue: 0.91), Color(red: 0.65, green: 0.67, blue: 0.70)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    private static let bronze = LinearGradient(
        colors: [Color(red: 0.80, green: 0.50, blue: 0.25), Color(red: 0.55, green: 0.32, blue: 0.14)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Splits the top 50 into 3 even-as-possible bands (17/17/16) --
    // rank 1 is the strongest affinity, so the best band is gold.
    private static func medalGradient(for rank: Int) -> LinearGradient {
        switch rank {
        case 1...17: return gold
        case 18...34: return silver
        default: return bronze
        }
    }

    var body: some View {
        Link(destination: spotifyURL) {
            HStack(spacing: 14) {
                Group {
                    if let url = artist.images?.first.flatMap({ URL(string: $0.url) }) {
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
                .frame(width: 48, height: 48)
                .clipShape(Circle())

                Text(artist.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)

                Spacer()

                if let rank {
                    HStack(spacing: 4) {
                        Image(systemName: "medal.fill")
                            .font(.subheadline)
                        Text("#\(rank)")
                            .font(.subheadline.bold().monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background {
                        Capsule().fill(Self.medalGradient(for: rank))
                    }
                }
            }
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(AppTheme.iconPlaceholderBackground)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.body)
                    .foregroundStyle(AppTheme.secondaryText)
            }
    }
}

#Preview {
    GenreStatsView(isActive: true)
}
