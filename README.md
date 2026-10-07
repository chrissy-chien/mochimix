# mochimix

A personal iOS app + Home Screen widget that shows your recent Spotify
listening activity — playlists, albums, artists, and (as a fallback)
individual tracks — right on your Home Screen, without needing to open
Spotify.

**Not affiliated with, endorsed by, or sponsored by Spotify.** "Spotify" is
a trademark of Spotify AB. This is a personal-use project, not a public
App Store release.

Licensed under the [MIT License](LICENSE).

---

## 1. App overview

mochimix is a SwiftUI iOS app with a companion WidgetKit extension. The app
itself handles logging in to Spotify, fetching your listening history, and
letting you configure what the widget shows. The widget is a separate,
sandboxed process that never talks to Spotify directly — it only displays
whatever the app most recently saved into a shared container.

Every play in your Spotify history is **normalized** down to one of four
"source item" types before it's shown anywhere in the app or widget:

- **Playlist** — if the track was played from a playlist, that playlist.
- **Album** — if it was played from an album (or the playlist lookup
  wasn't possible), the album.
- **Artist** — used when nothing more specific is available.
- **Track** — the last-resort fallback: the individual track itself.

This normalization is what lets the widget show "Late Night Drive" (a
playlist) instead of five separate track entries that all happened to come
from the same playlist.

## 2. Main functionality

### Spotify login (OAuth via PKCE)

- Login uses the **Authorization Code with PKCE** flow via
  `ASWebAuthenticationSession` — Spotify's login page opens in a secure,
  ephemeral system browser sheet, and Spotify redirects back to the app via
  the custom URL scheme `mochimix-login://callback`.
- PKCE means there is **no client secret** anywhere in this app — a random
  one-time "code verifier"/"code challenge" pair takes its place. This is
  the correct, Spotify-recommended flow for a mobile app that can't safely
  embed a permanent secret.
- Access and refresh tokens are stored in the iOS **Keychain**
  (`KeychainHelper.swift`), scoped to the app only — the widget extension
  never has access to them and never makes its own authenticated requests.
- Token refreshes are "single-flight": if multiple parts of the app notice
  the token needs refreshing at once, they all share one in-flight refresh
  request instead of racing each other (Spotify can invalidate a PKCE
  refresh token after its first use, so firing multiple refreshes
  concurrently could otherwise break sibling requests).

### Recently Played mode

The default widget mode. Shows your 5 most recent, deduplicated source
items: 1 large "most recent" tile plus 4 smaller tiles. The app fetches
more raw history entries than it needs (20, by default) because several
consecutive plays often collapse into the same source item once
normalized, and still leave enough left over to fill 5 *distinct* slots.

### Hybrid mode

The widget's top tile always shows your single most recent item (kept
fresh independent of pins); the 4 smaller tiles show your pinned items in
their exact chosen positions. Any pinned slot left empty is backfilled
with your next most recent items that aren't already shown, so the row
doesn't look sparse.

### Pinned Items mode

The widget shows exactly what you've pinned, in the 5 ordered slots you
arranged — including intentionally empty slots (shown as a subtle
placeholder, not backfilled). Nothing here changes automatically from your
listening activity.

### Pin search flow

Tapping an empty pinned slot opens a search sheet (`PinSearchView`) where
you can search Spotify for a **playlist, album, or artist** to pin
(individual tracks can't be pinned directly — they only ever appear as the
last-resort fallback for a played track). When the search field is empty,
the sheet instead shows quick "Recently Played" suggestions pulled from
your already-cached recent items, so pinning something recent doesn't
require typing a search query at all.

### Widget behavior and layout

- One widget kind, `mochimix_widget`, supporting the **medium**
  (`.systemMedium`) size only. (The Xcode template's Control Center widget
  and Live Activity have been removed — this app doesn't use either.)
- Layout: the top half shows the primary item's artwork, title, and
  subtitle, with a tappable "open Spotify" play button in the corner; the
  bottom half shows the 4 smaller tiles, evenly centered.
- Tapping any item's artwork/title opens that item's `open.spotify.com`
  link — a Universal Link straight into the Spotify app if it's installed,
  or a browser fallback otherwise.
- The widget extension **never makes network calls**. It reads pre-fetched
  data and pre-downloaded artwork files from the shared App Group
  container and re-renders whenever the app writes new data and calls
  `WidgetCenter.shared.reloadTimelines(...)`, or roughly every 10 minutes
  as a fallback request to iOS (which decides the actual refresh cadence;
  see "Known limitations" below).
- If the user isn't logged in, or the last refresh failed with nothing
  cached yet, the widget shows an explanatory empty state instead of a
  blank grid.

### Genre listening stats

The **Stats** tab shows a genre breakdown of your top artists across
Spotify's three affinity windows (4 Weeks / 6 Months / 1 Year), via `GET
/me/top/artists`, as either a bar list or a pie chart (a floating toggle
above the tab bar switches between them). Subgenres under the same
umbrella family (e.g. dubstep and house, both Electronic) render in the
same color — see `ParentGenre.swift`. The pie groups anything past the
top 6 genres into one "Other" wedge for readability.

Spotify's own per-artist `genres` field has been unreliable/empty since
around March 2025 (a widely-reported issue, confirmed independently via
this app's own debug log — not something fixable by changing how this app
calls Spotify's API). Instead, `GenreStatsStore` resolves each top
artist's genres from two external, Spotify-independent sources, tried in
order:

1. **getGenre.com** (`GetGenreAPIClient`, `GET /search?artist_id=...`) —
   queried by **exact Spotify artist ID** (getGenre's own `artist_id` is
   itself a Spotify ID, confirmed by testing), so there's no fuzzy
   name-matching risk. Requires a getGenre.com account (email + password
   in `Secrets.swift`) exchanged for a bearer token via
   `GetGenreAuthService` — a plain OAuth2 password grant, no
   browser/redirect needed. Showed no rate limiting across ~10 live test
   requests (no documented ceiling either, so `GenreStatsStore` still
   calls it sequentially rather than assuming that holds indefinitely).
2. **Last.fm** (`LastFMAPIClient`, `artist.gettoptags`) — used only when
   getGenre has no genres for that artist. Needs a free API key (see
   setup below).

An earlier version of this used MusicBrainz as the primary source
(matching what the Last.fm-tracking Discord bot
[Chuu](https://github.com/ishwi/Chuu) does by default) before switching
to getGenre, which turned out faster (single request by exact ID, vs.
MusicBrainz's 2-request name search-then-lookup under a strict ~1
request/second limit) and comparable in genre quality.

**Licensing note:** getGenre's data carries a Creative Commons
Attribution-NonCommercial-ShareAlike 4.0 license, but their (generic,
not API-specific) Terms of Service separately says content is for
"personal use... not for resale," which doesn't clearly address an app
redistributing their API responses to other users. This is accepted
knowingly for this personal, non-monetized project; if you fork this and
plan to distribute more widely or monetize, email
`support@getgenre.com` first for explicit permission — there's no
published commercial tier or self-serve license to buy.

Each artist's resolved genres are cached indefinitely per Spotify artist
ID (genre doesn't meaningfully change day to day), so this lookup is a
one-time cost per artist, not something repeated on every refresh.

### App settings

The Settings tab lets you configure, in order:

- **App Appearance** — System / Light / Dark, applied only to the app
  itself via `.preferredColorScheme(...)`. Doesn't affect the widget.
- **Widget Mode** — Recently Played / Pinned Items / Hybrid (see above).
- **Widget Font** — a horizontally scrollable picker with 17 options: 4
  built-in SwiftUI font designs (Default, Rounded, Serif, Monospace) plus
  13 named iOS system font families (Georgia, Typewriter, Courier,
  Baskerville, Avenir, Optima, Academy, Bodoni, Cochin, Futura, Galvji,
  Hiragina, Cursive). Applies to the widget's text only.
- **Widget Background** — a horizontally scrollable picker of background
  images, loaded from a JSON manifest (see below) rather than a hardcoded
  list.
- **Spotify Account** — shows your Spotify display name/avatar (fetched
  from `GET /v1/me` and cached) and a **Log Out** button, which clears
  Keychain tokens, cached recent items, cached widget display data, and
  cached genre stats (including the getGenre/Last.fm artist-genre cache).
  The getGenre account's own login token is unrelated to your Spotify
  session, so it's unaffected by logging out of Spotify.

### Theme / light & dark mode behavior

The app uses a custom named-color system (`Theme/AppTheme.swift` +
`Assets.xcassets` color sets), each with explicit light/dark variants,
rather than SwiftUI's generic `.primary`/`.secondary`/system-background
colors. This keeps the app's palette consistent and independent from
whatever a future OS-level default might change. The widget's text color
is **not** tied to the app's dark/light setting at all — it's derived
per-background (see below), since the widget's background is a photo, not
a solid system color.

### Background / font customization

- Background images live in `Shared/Backgrounds/` as PNGs, described by
  `Shared/Backgrounds/backgrounds.json` (`BackgroundOption`/
  `BackgroundManifest` in `BackgroundOption.swift`). Each entry names an
  image file and a `color` (`white` or `black`) — the hand-picked
  foreground text color that stays readable on that specific image. Adding
  a new background is just: drop a PNG in that folder and add one JSON
  entry — no Swift code changes needed.
- Font choice is purely a widget-text concern (see "Widget Font" above);
  it doesn't affect the app's own UI text.

### Caching & rate-limit behavior

This is the most involved part of the codebase (`ItemNormalizer.swift`,
`WidgetDataProvider.swift`, `SpotifyAPIClient.swift`):

- **Normalized recent items** (mode-independent, always "the last 5
  distinct source items") are cached to disk in the App Group container
  and reused across mode switches / pin changes without a network
  refetch — `WidgetDataProvider.refreshWidgetDisplayOnly()` recomputes the
  widget's mode-applied display purely from that cache.
- **Automatic refreshes are throttled**: at most once every 2 minutes
  when cached data already exists, to avoid hammering Spotify just because
  the app was foregrounded or the user switched tabs. A manual
  pull-to-refresh always bypasses this throttle.
- **429 (rate limit) handling**: `SpotifyAPIClient` detects a 429
  response explicitly (not by string-matching), parses the `Retry-After`
  header when present, and `ItemNormalizer` records a cooldown timestamp
  in the shared container so it's respected even across app relaunches.
  Real observed `Retry-After` values from Spotify for context lookups
  (playlist/album details) have been as long as ~17 hours.
- **Degraded fallback instead of blank results**: if a context lookup
  (e.g. "which playlist was this track played from?") is rate-limited,
  the item isn't dropped — it falls back to the track's own album (or the
  bare track, if even that's unavailable), and the UI is told this
  happened so it can show a "some items are simplified right now" notice
  instead of silently guessing or going blank.
- **Cache-safety invariant**: a failed or rate-limited refresh with
  nothing usable **never overwrites** previously cached good data. An
  empty result is only trusted as "you truly have no history" when there
  was no prior cache to fall back on.
- **Recently-played/currently-playing merge**: Spotify's recently-played
  endpoint can lag behind what's actually playing right now, so a manual
  refresh merges the freshly fetched top item with the previous cached top
  item (if different) rather than letting one silently replace the other
  before Spotify's history catches up.
- Downloaded artwork is cached to disk in the App Group container
  (`ImageCache.swift`) so the widget (which can't make network calls) can
  load it directly from a local file; unused cached artwork is pruned
  after every refresh.

### App Group / shared storage

Both the `mochimix` app target and the `mochimix-widgetExtension` target
declare the same App Group entitlement, `group.com.meowmeow.mochimix`.
`Shared/Services/SharedStore.swift` is the single choke point for that
shared container and is used by both targets to read/write:

- `recent_items.json` — the mode-independent normalized recent items.
- `widget_display.json` — the final mode-applied top item + 4 tiles the
  widget actually renders.
- An `Artwork/` subfolder of cached artwork image files.
- A shared `UserDefaults` suite (same App Group) holding widget settings
  (mode/font/background/appearance), pinned slots, login status flag, the
  last fetch error message (if any), and the persisted rate-limit cooldown
  timestamp.

Spotify tokens are deliberately **not** in this shared container — they
stay in the app's own Keychain, inaccessible to the widget extension, per
the architecture note in `KeychainHelper.swift`.

## 3. Project structure

```
mochimix/
├── mochimix.xcodeproj/          Xcode project file (single project, no SPM/CocoaPods)
├── mochimix/                    App target (bundle id: meowmeow.mochimix)
│   ├── mochimixApp.swift        @main entry point; handles the OAuth redirect URL,
│   │                            triggers a widget-data refresh on foreground
│   ├── ContentView.swift        Root view: LoginView (logged out) or a TabView
│   │                            (Recent + Settings) once logged in
│   ├── Info.plist                Declares the `mochimix-login` URL scheme
│   ├── mochimix.entitlements     App Group capability
│   ├── Assets.xcassets/          App icon, header/logo images, and the app's
│   │                            named color sets (light + dark variants)
│   ├── Theme/
│   │   └── AppTheme.swift        Named Color(...) constants pulled from Assets.xcassets
│   ├── Views/                    All app-only SwiftUI screens
│   │   ├── LoginView.swift           Spotify login screen
│   │   ├── RecentItemsView.swift     "Recent" tab: recent items + pinned editor
│   │   ├── PinnedSlotsView.swift     The 5-slot pinned-items editor grid
│   │   ├── PinSearchView.swift       Search-and-pin sheet
│   │   ├── GenreStatsView.swift      "Stats" tab: bar/pie genre breakdown by time range
│   │   └── SettingsView.swift        Widget mode/font/background + account settings
│   └── Services/                  App-only business logic (never used by the widget)
│       ├── SpotifyAuthService.swift   PKCE login/refresh, Keychain-backed tokens
│       ├── SpotifyAPIClient.swift     Typed Spotify Web API calls, 429 handling
│       ├── SpotifyModels.swift        Raw Spotify API response Decodable types
│       ├── ItemNormalizer.swift       Play history -> MochiMixItem resolution,
│       │                              rate-limit circuit breaker + degraded fallback
│       ├── MochiMixItemMapper.swift   Maps raw Spotify models -> MochiMixItem
│       ├── WidgetDataProvider.swift   Orchestrates refresh, caching, and pushing
│       │                              data + artwork to the shared container
│       ├── PinStore.swift             Manages the 5 pinned slots
│       ├── ProfileStore.swift         Caches the logged-in user's name/avatar
│       ├── GenreStatsStore.swift      Fetches Spotify top artists, resolves genres
│       │                              via getGenre then Last.fm, caches the breakdown
│       ├── ParentGenre.swift          Genre -> umbrella family classifier + colors
│       ├── GetGenreAuthService.swift  getGenre.com login (OAuth2 password grant),
│       │                              Keychain-backed token caching
│       ├── GetGenreAPIClient.swift    getGenre.com genre search client (by Spotify ID)
│       ├── GetGenreModels.swift       getGenre API response Decodable types
│       ├── LastFMAPIClient.swift      Minimal Last.fm Web API client (genre tags only)
│       ├── LastFMModels.swift         Last.fm API response Decodable types
│       ├── SettingsStore.swift        Wraps WidgetSettings, persists via SharedStore
│       ├── KeychainHelper.swift       Thin Keychain Services wrapper (tokens only)
│       ├── ImageCache.swift           Downloads/prunes cached artwork files
│       └── PinSearchViewModel.swift   Backs PinSearchView's search + recommendations
│
├── mochimix-widget/              Widget extension target
│                                (bundle id: meowmeow.mochimix.mochimix-widget)
│   ├── mochimix_widgetBundle.swift  @main WidgetBundle entry point (one widget kind)
│   ├── mochimix_widget.swift        TimelineProvider + the widget's SwiftUI layout
│   ├── Info.plist                    Declares this as a widgetkit-extension
│   ├── mochimix-widgetExtension.entitlements  App Group capability
│   └── Assets.xcassets/               Widget-only assets (accent color, app icon)
│
└── Shared/                       Files compiled into BOTH the app and widget targets
    ├── Models/                    Plain data types shared by both processes
    │   ├── MochiMixItem.swift          The normalized display item (both targets use this)
    │   ├── WidgetDisplayData.swift     Top item + 4 tiles, as written to the shared container
    │   ├── PinnedSlots.swift           5 ordered, possibly-empty pinned slots
    │   ├── WidgetSettings.swift        Mode/font/background/appearance, WidgetMode +
    │   │                              WidgetFontChoice enums
    │   └── AppColorScheme.swift        System/Light/Dark app appearance enum
    ├── Services/
    │   ├── SharedStore.swift           The single App Group read/write choke point
    │   ├── SpotifyConfig.swift         Client ID, redirect URI, scopes, App Group ID,
    │   │                              and other tunable constants (see below)
    │   ├── LastFMConfig.swift          Last.fm API key + base URL (genre stats fallback)
    │   ├── GetGenreConfig.swift        getGenre.com account + base/token URLs (genre stats primary)
    │   └── BundledResource.swift       Helper for loading bundled JSON/image resources
    └── Backgrounds/
        ├── backgrounds.json            Manifest of available widget backgrounds
        └── bg-*.png                    The background image files themselves
```

**For a beginner Swift/Xcode developer**, the mental model is: `Shared/`
compiles into *both* targets (it's how a playlist name gets from a Spotify
API response into a widget you can see on your Home Screen without the
widget ever touching the network itself), `mochimix/` is everything the
user directly interacts with and everything that talks to Spotify, and
`mochimix-widget/` is a deliberately "dumb," read-only renderer of
whatever `mochimix/` last wrote to the shared container.

## 4. Setup guide

### Requirements

- **Xcode** 16 or newer (this project uses `PBXFileSystemSynchronizedRootGroup`
  folder references, an Xcode 16+ project format feature — folders like
  `Shared/` and `Views/` sync to their target automatically; you don't
  need to manually add new files to the project in Xcode).
- **iOS deployment target**: 26.5 (`IPHONEOS_DEPLOYMENT_TARGET` in the
  project file). You'll need a matching or newer iOS Simulator runtime, or
  a physical device on that iOS version, installed in Xcode.
- Swift 5, targeting iPhone + iPad (`TARGETED_DEVICE_FAMILY = "1,2"`).
- No Swift Package Manager, CocoaPods, or Makefile — it's a single, plain
  `.xcodeproj`.

### 1. Open the project

Open `mochimix/mochimix.xcodeproj` in Xcode.

### 2. Signing

Both the `mochimix` and `mochimix-widgetExtension` targets use **Automatic**
code signing. The first time you build, Xcode will prompt you to pick a
development team — go to Xcode → Settings → Accounts, add your Apple ID if
you haven't already, then select your personal team for both targets under
their **Signing & Capabilities** tab.

### 3. App Group setup

Both targets already declare the App Group `group.com.meowmeow.mochimix`
in their entitlements files. If you fork this under your own Apple
Developer account/bundle ID, that exact group ID likely won't be available
to you, so:

1. Select the **mochimix** target → **Signing & Capabilities** → the App
   Groups capability → create/select a group ID your own team owns.
2. Do the same for the **mochimix-widgetExtension** target, using the
   *exact same* group ID as step 1 (this is what lets the two processes
   share data — a mismatch here is the most common cause of the app
   crashing on launch with a "Could not open App Group" error).
3. Update `appGroupIdentifier` in `Shared/Services/SpotifyConfig.swift` to
   match.

### 4. URL scheme setup

`mochimix/Info.plist` already declares the custom URL scheme
`mochimix-login` (`CFBundleURLName: com.meowmeow.mochimix.login`). This is
what lets iOS hand control back to this specific app after Spotify's login
page redirects to `mochimix-login://callback`. If you change the redirect
URI (step 6 below), this scheme must be updated to match.

### 5. Spotify Developer Dashboard setup

1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard)
   and create an app (or use an existing one).
2. Note the **Client ID** shown on the app's overview page.
3. Open **Settings** on that app and add a **Redirect URI** (step 6).
4. New apps start in **Development Mode**, which only allows explicitly
   allow-listed Spotify accounts to log in (up to 25). Go to **User
   Management** on your app's dashboard page and add your own Spotify
   account (and anyone else you want to be able to log in) — otherwise
   login will fail even with a correct Client ID/redirect URI.

### 6. Spotify redirect URI

Add exactly this Redirect URI in your Spotify app's dashboard settings:

```
mochimix-login://callback
```

It must match, character-for-character, both the URL scheme registered in
`mochimix/Info.plist` and the `redirectURI` constant in
`Shared/Services/SpotifyConfig.swift`.

### 7. Spotify scopes used by this app

Declared in `SpotifyConfig.scope`:

- `user-read-recently-played` — the core "what have you been listening to"
  data.
- `user-read-currently-playing`, `user-read-playback-state` — used to keep
  the "most recent item" feeling current even when Spotify's
  recently-played history endpoint lags behind.
- `playlist-read-private`, `playlist-read-collaborative` — needed to fetch
  full playlist details (name, artwork, owner) for a private or
  collaborative playlist via `GET /v1/playlists/{id}`, even for playlists
  you own. Without these, that lookup 403s for any non-public playlist.
- `user-top-read` — needed for `GET /me/top/artists`, which the Stats
  tab's genre breakdown is built on.

No write scopes are requested — this app only ever reads your listening
history and playlist/album/artist metadata.

### 8. Where the Spotify Client ID (and genre-stats credentials) live

You need your own Spotify Client ID. The Stats tab's genre breakdown
also needs:

- A **getGenre.com account** (sign up and verify your email at
  [getgenre.com](https://www.getgenre.com) — free, no paid tier) — this
  is the primary genre source, queried via `GetGenreAuthService`'s
  OAuth2 password grant (your account email + password, not a simple API
  key). See the licensing note in "Genre listening stats" above before
  using this beyond personal use.
- A free **Last.fm API key** from
  [last.fm/api/account/create](https://www.last.fm/api/account/create)
  (no approval wait) — the fallback, only consulted when getGenre has
  nothing for an artist.

Create `Shared/Services/Secrets.swift` yourself (this path is already
covered by `.gitignore`) — the project won't compile until this file
exists:

```swift
import Foundation

nonisolated enum Secrets {
    static let spotifyClientID = "YOUR_SPOTIFY_CLIENT_ID"
    static let lastFMAPIKey = "YOUR_LASTFM_API_KEY"
    static let getGenreEmail = "YOUR_GETGENRE_EMAIL"
    static let getGenrePassword = "YOUR_GETGENRE_PASSWORD"
}
```

Replace each placeholder with your own values from the steps above.
Since `Shared/` is one of this project's synchronized folders (see
"Requirements" above), Xcode picks up the new file automatically — no
manual "add to target" step needed. If you skip the Last.fm key, the app
still builds and runs fine — the Stats tab will just show less complete
genre data (whatever getGenre alone can resolve) instead of "No genre
data yet" for every time range. Skipping the getGenre credentials means
every artist falls through to Last.fm instead.

### 9. Running on Simulator

```bash
cd mochimix
xcodebuild -project mochimix.xcodeproj -scheme mochimix -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

(Swap `iPhone 17` for any simulator you have installed —
`xcrun simctl list devices available` lists your options.) In practice,
opening the project in Xcode and running the **mochimix** scheme (Cmd-R)
is the fastest inner loop, especially since widget layout is much easier
to iterate on via `#Preview` in `mochimix_widget.swift` than via headless
builds.

### 10. Running on a physical iPhone

1. Connect your iPhone and select it as the run destination in Xcode.
2. Make sure your Apple ID/team is selected for both targets (step 2
   above) — a physical device requires a provisioning profile, which
   Automatic signing generates for you.
3. Build & Run (Cmd-R). The first launch on-device may require trusting
   your developer certificate under **Settings → General → VPN & Device
   Management** on the phone.

### 11. Adding the widget after installing the app

1. Build and run the app at least once and log in, so it has fetched some
   real data into the shared container — the widget shows a "log in"
   empty state until then.
2. On the Home Screen, long-press an empty area → tap the **+** in the top
   corner → search for "mochimix" → add the medium-size widget (it's the
   only supported size).
3. Tap the top item, any of the 4 tiles, or the play button to open that
   item (or Spotify generally) via a Universal Link.

## 5. Development notes

- **Refresh/caching**: see the "Caching & rate-limit behavior" section
  above — the short version is: normalized recent items are cached
  independently of widget mode, refreshes are throttled to once per 2
  minutes automatically (bypassable via pull-to-refresh), a persisted
  rate-limit cooldown survives app relaunches, and a failed/rate-limited
  refresh never overwrites good cached data.
- **Widget data generation**: the app (`WidgetDataProvider`) computes the
  mode-applied `WidgetDisplayData` (top item + 4 tiles) from the cached
  recent items + pinned slots, downloads/caches artwork locally, writes
  both to the shared App Group container, then calls
  `WidgetCenter.shared.reloadTimelines(...)`. The widget extension itself
  never fetches anything — its `TimelineProvider` just re-reads what's
  already on disk.
- **Pinned items storage**: stored as 5 fixed, ordered, possibly-`nil`
  slots (`PinnedSlots`, in the shared container) rather than a plain
  array, so a specific empty position is preserved and the pinned-slots
  editor always knows exactly which slot to show a "+" in. A legacy
  unordered `pinned_items` format is auto-migrated into slots on first
  read if found.
- **Debug logging**: in DEBUG builds, `debugLog(_:)` (defined in
  `mochimixApp.swift`) appends timestamped lines to `debug_log.txt` inside
  the shared App Group container, in addition to `print()`. This exists
  because Simulator console capture for background/widget-adjacent code
  can be unreliable — reading that file directly (from the container path
  under `~/Library/Developer/CoreSimulator/Devices/<device>/data/Containers/Shared/AppGroup/<id>/debug_log.txt`
  on Simulator) is often the most reliable way to see what actually
  happened during a refresh. It never logs token values.

### Known limitations

- **Widgets can't self-schedule refreshes.** iOS decides the actual
  refresh cadence for a widget's timeline provider based on a per-widget
  budget (how often you look at it, system power state, etc.) — this app
  *requests* a re-check roughly every 10 minutes, but that's not a
  guarantee. In practice the widget reliably updates right after you open
  the app (which explicitly triggers a refresh + `reloadTimelines` call),
  but passive background updates aren't guaranteed on any fixed schedule.
  A `BGAppRefreshTask` (Background Tasks framework) would be the next step
  for more aggressive background refreshing, and isn't implemented yet.
- Only the medium widget size is supported; there's no small or large
  layout, no Lock Screen widget, no Control Center widget, and no Live
  Activity (the Xcode template's versions of these were removed).
- No automated test target exists in the project.
- Spotify's real rate limits for this app's context lookups (playlist/
  album detail fetches) have been observed to impose multi-hour
  `Retry-After` cooldowns; during that window, some items will show
  "degraded" (track/album-only) attribution rather than full
  playlist detail, by design (see above), rather than going blank.

### Troubleshooting

- **"Could not open App Group UserDefaults" crash on launch**: the App
  Group ID in both targets' entitlements doesn't match, or the capability
  isn't enabled for your signing team. Re-check step 3 in Setup.
- **Login redirects back to Safari/nothing happens**: the Redirect URI
  registered in the Spotify Dashboard doesn't exactly match
  `mochimix-login://callback`, or `Info.plist`'s URL scheme was changed
  without updating `SpotifyConfig.redirectURI` to match.
- **Widget stuck on "Log in to mochimix..."**: the app hasn't completed a
  successful login + at least one refresh yet, or you're looking at a
  freshly-added widget instance before the app's first foreground refresh
  has run — open the app once.
- **"Spotify is rate-limiting..." message won't go away**: this reflects a
  real Spotify-side `Retry-After` cooldown (can be several hours for
  detailed playlist/album lookups) — it's not a bug, and the app/widget
  fall back to simplified (track/album-only) data during that window
  rather than showing nothing.
- **New Swift files not showing up in the build**: this project uses
  Xcode 16's synchronized folder groups (`Shared/`, `Views/`, `Services/`,
  etc. all sync automatically) — if a new file genuinely isn't being
  compiled, check it was saved inside one of the existing target folders
  rather than elsewhere, and that Xcode's file explorer shows it under the
  right target.
- **Stale-looking Xcode errors ("cannot find type X in scope") for types
  that are clearly defined elsewhere**: often just SourceKit indexer lag,
  not a real compile error — a clean build (Cmd-Shift-K then Cmd-B) or
  restarting Xcode usually resolves it.
- **Stats tab always shows "No genre data yet"**: check —
  1. If `user-top-read` was added to `SpotifyConfig.scope` after you'd
     already logged in once, your existing session's token doesn't have
     it. Log out and back in so Spotify can grant the added scope.
  2. `Secrets.swift` still has the `getGenreEmail`/`getGenrePassword`
     placeholders (or the account's email isn't verified yet) —
     `GetGenreAuthService`'s login will fail and every artist falls
     through to Last.fm, which needs its own valid key to pick up the
     slack (see next point).
  3. `Secrets.swift` still has the `lastFMAPIKey` placeholder (or an
     invalid key) — this only matters for artists getGenre couldn't
     resolve, so it won't cause a fully-empty Stats tab by itself, but it
     does mean less complete coverage. Get a free key from
     [last.fm/api/account/create](https://www.last.fm/api/account/create).
- **Switching away from the Stats tab mid-resolve**: safe — `GenreStatsStore`
  owns its own refresh task independent of the view, so it keeps resolving
  in the background rather than being cancelled (this was a real bug once,
  surfacing as spurious `NSURLErrorCancelled`/-999 failures; fixed by that
  task ownership change).

## 6. Privacy / security notes

### What this app accesses from your Spotify account

With the scopes listed above, mochimix can read (but never write/modify):

- Your recently played tracks and currently-playing state.
- Metadata (name, artwork, owner) for playlists, albums, and artists,
  including your own private and collaborative playlists.
- Your top artists over 3 time windows (used for the Stats tab).
- Your Spotify profile display name and avatar image.

It never posts, follows, modifies playlists, or takes any write action
against your Spotify account.

### What this app sends to getGenre and Last.fm

The Stats tab's genre breakdown sends your top artists' **Spotify artist
IDs** to getGenre.com (e.g. `4Z8W4fKeB5YxbusRsdQVPb` for Radiohead — an
opaque Spotify catalog identifier, not anything tied to your personal
Spotify account), and — only when getGenre has nothing for an artist —
sends **artist names only** (e.g. "Tame Impala") to Last.fm's public
`artist.gettoptags`. Neither ever receives your Spotify identity,
account, email, or listening history as a whole.

Unlike Last.fm's plain unauthenticated GETs, requests to getGenre are
authenticated as a getGenre.com account (see setup above) — that
account's email/password live in `Secrets.swift`, which is gitignored
and never committed, but **is compiled into the app binary as plain
text**, same as the Spotify Client ID and Last.fm key already are. For a
personal, non-distributed build this is a non-issue; if you ever
distribute a build of this app to others, anyone who decompiles it could
recover those credentials, so treat them accordingly (e.g. a
dedicated/throwaway getGenre account rather than one used elsewhere).

Results from both services are cached locally per artist indefinitely,
so the same popular artist isn't re-sent on every refresh.
