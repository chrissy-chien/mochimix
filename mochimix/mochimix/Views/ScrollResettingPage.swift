//
//  ScrollResettingPage.swift
//  mochimix
//

import SwiftUI

/// A `ScrollView` wrapper used by every main/sub page: resets scroll
/// position to the top if the page was inactive (switched away from via
/// tab tap or swipe) for more than `resetAfter` -- a short glance at
/// another tab keeps your place, as normal, but coming back after a few
/// minutes starts you back at the top rather than wherever you happened
/// to leave off. Also centralizes the `scrollContentBackground(.hidden)`/
/// `scrollBounceBehavior(.basedOnSize)` pair every page already wanted,
/// and optionally wires up pull-to-refresh.
struct ScrollResettingPage<Content: View>: View {
    let isActive: Bool
    var resetAfter: TimeInterval = 120
    /// `.always` lets a page bounce even when its content fits on screen.
    var bounce: ScrollBounceBehavior = .basedOnSize
    var onRefresh: (() async -> Void)?
    @ViewBuilder var content: () -> Content

    @State private var inactiveSince: Date?
    private let topID = "scrollResettingPageTop"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content()
                    .id(topID)
            }
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(bounce)
            .modifier(ConditionallyRefreshable(onRefresh: onRefresh))
            .onChange(of: isActive) { _, nowActive in
                if nowActive {
                    if let inactiveSince, Date().timeIntervalSince(inactiveSince) > resetAfter {
                        withAnimation {
                            proxy.scrollTo(topID, anchor: .top)
                        }
                    }
                    inactiveSince = nil
                } else if inactiveSince == nil {
                    inactiveSince = Date()
                }
            }
        }
    }
}

/// `.refreshable` has no "off" state of its own -- this lets
/// `ScrollResettingPage` skip it entirely for pages with nothing to
/// pull-refresh (e.g. Settings) instead of showing a spinner affordance
/// that does nothing.
private struct ConditionallyRefreshable: ViewModifier {
    let onRefresh: (() async -> Void)?

    func body(content: Content) -> some View {
        if let onRefresh {
            content.refreshable { await onRefresh() }
        } else {
            content
        }
    }
}
