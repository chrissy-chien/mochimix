//
//  SettingsView.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import SwiftUI
import WidgetKit

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var auth: SpotifyAuthService
    let isActive: Bool
    /// Whether the Customize Widget page is pushed.
    @Binding var isCustomizingWidget: Bool
    @ObservedObject private var profileStore = ProfileStore.shared
    @Environment(\.openURL) private var openURL

    private static let widgetKind = "mochimix_widget"

    var body: some View {
        NavigationStack {
            // A plain ScrollView (rather than Form) so the Mode section can
            // use custom button rows instead of list-style pickers -- they'd
            // look and behave oddly nested inside Form's List chrome.
            ScrollResettingPage(isActive: isActive) {
                VStack(alignment: .leading, spacing: 28) {
                    modeSection
                    customizeWidgetRow
                    appearanceSection
                    accountSection
                }
                .padding()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                PageTitle(title: "Settings")
            }
            .background(AppTheme.background)
            // Driven by a binding (not a NavigationLink) so ContentView can
            // pop back to the main Settings page -- see ContentView.
            .navigationDestination(isPresented: $isCustomizingWidget) {
                WidgetCustomizationView(settingsStore: settingsStore)
            }
            // Mode changes don't need fresh Spotify data -- just a
            // different view of what's already cached.
            .onChange(of: settingsStore.settings.mode) { _, _ in
                Task { await WidgetDataProvider.shared.refreshWidgetDisplayOnly() }
            }
            .onChange(of: settingsStore.settings.appColorScheme) { _, _ in
                // Only the widget's *text color* depends on this (see
                // mochimix_widget.swift) -- reload so it picks that up.
                WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
            }
        }
    }

    // MARK: - Appearance (app-wide dark/light/system)

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App Appearance").font(.headline)
                .foregroundStyle(AppTheme.primaryText)

            VStack(alignment: .leading, spacing: 10) {
                Picker("Appearance", selection: $settingsStore.settings.appColorScheme) {
                    ForEach(AppColorScheme.allCases) { scheme in
                        Text(scheme.displayName).tag(scheme)
                    }
                }
                .pickerStyle(.segmented)
                Text("Changes only affect the app. The widget isn't affected; its text color is set by your chosen background instead.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .sectionCardBackground()
        }
    }

    // MARK: - Widget Mode
    //
    // Three separate button rows (not a segmented control), each showing a
    // checkmark + accent-colored text when selected. The explanation text
    // sits below the row group but outside of it -- its own element, not
    // another row.

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Widget Mode").font(.headline)
                .foregroundStyle(AppTheme.primaryText)

            VStack(alignment: .leading, spacing: 6) {
                VStack(spacing: 1) {
                    ForEach(WidgetMode.allCases) { mode in
                        ModeRow(
                            mode: mode,
                            isSelected: mode == settingsStore.settings.mode,
                            action: { settingsStore.settings.mode = mode }
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(settingsStore.settings.mode.explanation)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .animation(.default, value: settingsStore.settings.mode)
            }
        }
    }

    // MARK: - Customize Widget (pushes WidgetCustomizationView)

    private var customizeWidgetRow: some View {
        Button {
            isCustomizingWidget = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "paintbrush.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Customize Widget")
                        .foregroundStyle(AppTheme.primaryText)
                    Text("Font and background, with a live preview")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .sectionCardBackground()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Account

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spotify Account").font(.headline)
                .foregroundStyle(AppTheme.primaryText)

            VStack(alignment: .leading, spacing: 12) {
                if auth.isLoggedIn {
                    profileRow

                    Button(role: .destructive) {
                        auth.logOut()
                        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
                    } label: {
                        Text("Log Out")
                            .frame(maxWidth: .infinity)
                    }
                    .font(.callout)
                    .buttonStyle(.bordered)
                } else {
                    Text("Not logged in")
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .sectionCardBackground()
        }
        .task {
            if profileStore.displayName == nil {
                await profileStore.refresh()
            }
        }
    }

    /// Tapping opens the user's Spotify profile, same as the header avatar.
    private var profileRow: some View {
        Button {
            if let url = profileStore.profileURL { openURL(url) }
        } label: {
            HStack(spacing: 16) {
                ProfileAvatar(size: 54)

                Text(profileStore.displayName?.isEmpty == false ? profileStore.displayName! : "Spotify User")
                    .font(.body)
                    .foregroundStyle(AppTheme.primaryText)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens your Spotify profile")
    }
}

private struct ModeRow: View {
    let mode: WidgetMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(mode.displayName)
                    .foregroundStyle(isSelected ? Color.accentColor : AppTheme.primaryText)
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(AppTheme.cardBackground)
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func sectionCardBackground() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.cardBackground)
            }
    }
}

#Preview {
    SettingsView(settingsStore: .shared, auth: .shared, isActive: true, isCustomizingWidget: .constant(false))
}
