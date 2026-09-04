# AGENTS.md

Fork of [aaronpk/Overland-iOS](https://github.com/aaronpk/Overland-iOS).

## Build

Requires Xcode 27+, CocoaPods, minimum deployment target iOS 17.0.

```bash
pod install
xcodebuild -workspace Overland.xcworkspace -scheme Overland \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

- `Podfile` post_install bumps pod deployment targets to 17.0 and patches the
  AFNetworking 4.0.1 `netinet6/in6.h` private-module header include (errors on
  modern SDKs). If you add pods, keep both hooks.
- Simulator names: `iPhone 17 Pro` / `iPhone 17 Pro Max` (no plain "iPhone 17").

## Run / test on simulator

```bash
./ci_scripts/smoke_test.sh            # build, install, launch, set location, screenshot
./ci_scripts/idb_ui_test.sh           # drive tabs via Facebook IDB (needs idb_companion)
xcrun simctl location booted set 45.5152,-122.6784   # set location
xcrun simctl openurl booted "overland://setup?url=https%3A%2F%2Fhost%2Fpath"  # configure endpoint
```

IDB notes: start the companion detached (`setsid idb_companion --udid $UDID &`),
connect with `idb connect localhost 10882`. Screenshots land in `screenshots/`.

## Architecture

- **Core stays Objective-C**: `GLManager` (~2.3k lines) owns location, queueing
  (LOLDatabase/SQLite), batching, and HTTP. Don't rewrite it.
- **UI is SwiftUI** (`GPSLogger/*.swift`), hosted from SceneDelegate via
  `UIHostingController`; `Main.storyboard` only instantiates TipJar and
  TripSettings legacy screens (by storyboard ID).
- **`GLManagerBridge`** (`@Observable`) is the only bridge: views read live
  status from it and write settings through it so GLManager side effects run.
- **`OverlandLocationEngine`** is the standard-update source (iOS 17
  `CLLocationUpdate.liveUpdates` + `CLBackgroundActivitySession`). The
  CLLocationManager delegate path remains for significant-change, heading,
  region, and visit events. Feeds `-[GLManager processEngineLocation:]`.
- WiFi zones: `WifiZones` defaults key, array of `{name, latitude, longitude[,
  bssid]}` dicts; legacy single-zone keys migrate on first access. Matching is
  SSID-first, BSSID tiebreaker.

## Code style

Match the existing Obj-C: `#pragma mark -` sections, terse names, flat logic
with early returns, `static NSString *const` defaults keys, direct
NSUserDefaults access. No comments restating what code does. Swift: one file
per screen, flat `Form`/`Section`, `@Observable` only in the bridge, Liquid
Glass APIs behind `if #available(iOS 26, *)` with `.borderedProminent` /
`.ultraThinMaterial` fallbacks.

## Remotes

- `origin` → this fork (push here)
- `upstream` → aaronpk/Overland-iOS (fetch only; never push without owner approval)
