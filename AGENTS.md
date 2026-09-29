# AGENTS.md

Fork of [aaronpk/Overland-iOS](https://github.com/aaronpk/Overland-iOS).

## Build

Requires Xcode 27+, CocoaPods, minimum deployment target iOS 17.0.

```bash
pod install
nice -n 10 xcodebuild -jobs 2 -workspace Overland.xcworkspace -scheme Overland \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

- `Podfile` post_install bumps pod deployment targets to 17.0 and patches the
  AFNetworking 4.0.1 `netinet6/in6.h` private-module header include (errors on
  modern SDKs). If you add pods, keep both hooks.
- Simulator names: `iPhone 17 Pro` / `iPhone 17 Pro Max` (no plain "iPhone 17").
- Run only one build at a time, using `nice -n 10` and `-jobs 2`, as the owner
  requested. Do not increase build concurrency. These are scheduling controls,
  not a hard CPU-percentage cap. Keep `BUILD_JOBS=2` for the smoke script.

## Regression tests

```bash
nice -n 10 xcodebuild -jobs 2 -workspace Overland.xcworkspace -scheme Overland \
  -destination 'platform=iOS Simulator,name=Overland Regression' \
  -parallel-testing-enabled NO test
```

Create a separate iPhone 17 Pro simulator named `Overland Regression` first.
Tests use an in-memory queue and mocked `overland.test` requests. Do not run
these on a simulator containing important trial data; tests replace app preferences temporarily.

## Simulator resource limit

Keep at most one simulator booted at a time. Shut down the trial simulator before
regression or fake-route testing, then stop the test simulator before reopening the trial.

## Run / test on simulator

```bash
./ci_scripts/smoke_test.sh            # build, install, launch
./ci_scripts/idb_ui_test.sh           # drive tabs via Facebook IDB (needs idb_companion)
xcrun simctl location booted set 45.5152,-122.6784   # set location
xcrun simctl openurl booted "overland://setup?url=https%3A%2F%2Fhost%2Fpath"  # configure endpoint
```

IDB notes: start the companion detached (`setsid idb_companion --udid $UDID &`),
connect with `idb connect localhost 10882`. Screenshot capture is off by default.
Only capture when the owner requests it; `CAPTURE_SCREENSHOTS=1` writes to `Screenshots/`.

## Architecture

- **Core stays Objective-C**: `GLManager` (~2.3k lines) owns location, queueing
  (LOLDatabase/SQLite), batching, and HTTP. Don't rewrite it.
- **Screens are SwiftUI** (`GPSLogger/*.swift`). SceneDelegate creates the root
  hosting controller; `NativeTabController` owns the system tab bar and retains
  the shared map host. `MapControlPanel` hosts Tracker/Trip controls behind the
  native bar. Settings has its own host and inherits the tab controller's safe
  areas. `Main.storyboard` only instantiates the legacy TipJar screen (by storyboard ID).
- **`GLManagerBridge`** (`@Observable`) is the only bridge: views read live
  status from it and write settings through it so GLManager side effects run.
- **Route replay**: `RecentLocationHistory` archives each accepted upload record
  in a separate 24-hour SQLite store. `GLManager` calls it after the queue attempt;
  the archive never participates in queue deletion or HTTP. `HistoryPlaybackModel`
  owns only presentation state and stops its timer off the Tracker tab.
- **`OverlandLocationEngine`** uses iOS 17 `CLLocationUpdate.liveUpdates` for
  Best accuracy with automatic pausing, plus `CLBackgroundActivitySession`.
  `GLManager` uses standard CLLocationManager updates for custom/navigation
  accuracy or disabled pausing; liveUpdates cannot express those settings.
  Delegate paths also handle significant-change, region, and visit events.
  Live updates feed `-[GLManager processEngineLocation:]`.
- WiFi zones: `WifiZones` defaults key, array of `{name, latitude, longitude[,
  bssid]}` dicts; legacy single-zone keys migrate on first access. Matching is
  SSID-first, BSSID tiebreaker.

## Code style

Match the existing Obj-C: `#pragma mark -` sections, terse names, flat logic
with early returns, `static NSString *const` defaults keys, direct
NSUserDefaults access. No comments restating what code does. Swift: one file
per screen, flat `Form`/`Section`, and `@Observable` for the bridge and shared
replay presentation state. Keep Liquid Glass APIs behind `if #available(iOS 26, *)`
with `.borderedProminent` /
`.ultraThinMaterial` fallbacks.

## Writing

Use the installed `better-writing` skill for documentation, comments, UI copy,
and prose reviews. Read `~/.codex/skills/better-writing/SKILL.md` before the first
writing pass. Keep API names, attribution, code examples, and technical caveats.
Describe current behavior; remove stale progress notes and unsupported claims.
Comments should explain constraints or decisions that the code does not show.

## Remotes

- `origin` → this fork (push here)
- `upstream` → aaronpk/Overland-iOS (fetch only; never push without owner approval)
