//
//  TopBar.swift
//  mochimix
//

import SwiftUI

/// The logged-in user's circular Spotify profile photo, falling back to a
/// person glyph while it loads or if they have no photo. Shared by the
/// app header and the Settings profile row.
struct ProfileAvatar: View {
    @ObservedObject private var profileStore = ProfileStore.shared
    let size: CGFloat

    var body: some View {
        Group {
            if let url = profileStore.avatarURL {
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
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        Circle()
            .fill(AppTheme.iconPlaceholderBackground)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(AppTheme.secondaryText)
            }
    }
}

// MARK: - Top bar
//
// The top bar is one translucent, blurred band covering the status bar,
// the app header (avatar + logo) and the current page's title. The app
// header floats over the pages with no background of its own (see
// RootShellView); each page draws the band itself, via PageTitle, so the
// band and title slide together when swiping between tabs, and content
// scrolls up behind it. The paged TabView clips its pages to its own
// frame, so it ignores the top safe area to let pages reach the top of
// the screen; pages still lay out below the status bar, and
// `topChromeHeight` tells them how much more room the floating header
// takes below that.

extension EnvironmentValues {
    /// Height of the floating app header (below the status bar). 0 when
    /// no header is showing.
    @Entry var topChromeHeight: CGFloat = 0
}

/// A main page's title ("Recent", "Settings", ...) plus the top-bar
/// band behind it. Pages attach it with `.safeAreaInset(edge: .top)` so
/// it stays pinned while their content scrolls up behind it. Stats has
/// more fixed chrome under its title, so it puts the title and that
/// chrome in one inset and applies `topBarBackground()` to the whole
/// thing instead (`hasBackground: false`).
struct PageTitle: View {
    let title: String
    var hasBackground = true
    /// Shows a back chevron before the title (for pushed pages, which hide
    /// the system navigation bar so they keep this same top bar).
    var onBack: (() -> Void)?
    @Environment(\.topChromeHeight) private var topChromeHeight

    var body: some View {
        let text = HStack(spacing: 6) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }

            Text(title)
                .font(.title2.bold())
                .foregroundStyle(AppTheme.primaryText)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, topChromeHeight + 12)
            .padding(.bottom, 12)

        if hasBackground {
            text.topBarBackground()
        } else {
            text
        }
    }
}

/// Pushed pages hide the system navigation bar (PageTitle draws its own
/// back button), which also switches off iOS's left-edge swipe-to-go-back.
/// Re-enabling the gesture's delegate brings it back; it's only allowed to
/// begin when there's actually a page to pop.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    // Re-applied on every layout: SwiftUI turns the gesture back off when
    // it hides the bar for a newly pushed page.
    override open func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        interactivePopGestureRecognizer?.isEnabled = true
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

extension View {
    /// The slightly see-through, blurred top-bar backdrop: a system
    /// material for the blur, tinted with the app background so it still
    /// reads as the app's own color. Extends up behind the status bar.
    func topBarBackground() -> some View {
        background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(AppTheme.background.opacity(0.45))
                .ignoresSafeArea(edges: .top)
        }
    }
}

