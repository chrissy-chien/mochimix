# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

`mochimix` is an iOS app with a WidgetKit extension, intended to become a Spotify "now playing" widget (repo name: `spotify-widget`). The project is currently at the Xcode-template stage — the app, widget, control widget, and Live Activity are all still boilerplate placeholder code (emoji timeline entries, "Hello, world!", a timer control) with no Spotify integration implemented yet.

Two pieces of scaffolding already point at the intended design:
- A custom URL scheme `mochimix-login` (`CFBundleURLName: com.meowmeow.mochimix.login`) is registered in the app's `Info.plist` — this is the redirect URI target for Spotify OAuth (Authorization Code flow), so the app expects to handle the callback in its `onOpenURL`.
- Both the app and the widget extension carry the `group.com.meowmeow.mochimix` App Group entitlement — this is how the main app (which will hold the Spotify auth session / access token) is meant to share now-playing data with the widget extension (e.g. via a shared `UserDefaults(suiteName:)` container or shared file, since widget extensions can't make their own authenticated network calls without the token).

## Build & run

This is a plain Xcode project (no Swift Package Manager, CocoaPods, or Makefile) — there's a single project file at `mochimix/mochimix.xcodeproj`. All commands below should be run from `mochimix/`.

```bash
# List schemes/targets
xcodebuild -list -project mochimix.xcodeproj

# Build the app (Debug, simulator)
xcodebuild -project mochimix.xcodeproj -scheme mochimix -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Build the widget extension target
xcodebuild -project mochimix.xcodeproj -scheme mochimix-widgetExtension -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

There is currently no test target in the project, so there is no `xcodebuild test` invocation to run. In practice, opening `mochimix/mochimix.xcodeproj` in Xcode and running the `mochimix` scheme is the fastest inner loop, since widgets/Live Activities are much easier to iterate on via Xcode previews (`#Preview`) than headless builds.

Deployment target is iOS 26.5 (`IPHONEOS_DEPLOYMENT_TARGET`), Swift 5, targeting iPhone + iPad (`TARGETED_DEVICE_FAMILY = "1,2"`).

## Architecture

The Xcode project has two targets that map to two directories:

- **`mochimix/`** — the host app target (bundle id `meowmeow.mochimix`). `mochimixApp.swift` is the `@main` entry point; `ContentView.swift` is the root view. This is where Spotify auth (OAuth via the `mochimix-login` URL scheme) and any user-facing UI will live.
- **`mochimix-widget/`** — the widget extension target (bundle id `meowmeow.mochimix.mochimix-widget`), built as a `WidgetBundle` (`mochimix_widgetBundle.swift`) containing three widget kinds that all currently need to be repurposed for "now playing" data instead of their template content:
  - `mochimix_widget.swift` — the home/lock screen widget (`AppIntentTimelineProvider` + `AppIntentConfiguration`). `AppIntent.swift` defines the widget's configurable `ConfigurationAppIntent`.
  - `mochimix_widgetControl.swift` — a Control Center / Action Button `ControlWidget` (currently a placeholder timer toggle).
  - `mochimix_widgetLiveActivity.swift` — an `ActivityKit` Live Activity + Dynamic Island layout (currently a placeholder emoji activity) — the natural fit for live Spotify playback status.

Because the widget extension is a separate process/sandbox from the app, any real implementation needs a data-sharing layer through the shared App Group container (`group.com.meowmeow.mochimix`) — look for/introduce this before wiring real Spotify data into the timeline providers, since the widget can't independently hold or refresh OAuth tokens the way the app can.
