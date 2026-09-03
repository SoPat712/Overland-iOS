# Overland-iOS Fork: Implementation Plan (v2 — verified & corrected)

> Supersedes `/Users/joshp/.kimi/plans/ravager-icon-us-agent.md`. All line numbers and facts
> re-verified against the working tree on 2026-09-03.

## Verified Environment (corrections to prior plans in **bold**)

| Fact | Value |
|------|-------|
| Xcode | **27.0 (27A5252f), iOS 27 SDK** |
| Simulators | **iPhone 17 Pro / Pro Max only — "iPhone 17" does not exist** |
| gh auth | SoPat712, **SSH protocol** ✅ |
| Remotes | `origin` → `aaronpk/Overland-iOS` (needs rename to `upstream`) |
| Podfile platform | `ios '11.0'` |
| Deployment targets | **project-level = 14.0 AND target-level = 15.0 — both must be bumped** |
| Swift files | Zero (100% Obj-C) |
| Bridging header | Empty file at `GPSLogger/Overland-Bridging-Header.h`, **but already wired**: `SWIFT_OBJC_BRIDGING_HEADER` build setting present, Swift 5.0 enabled — zero project changes needed to start writing Swift |
| GLManager.m | 2,108 lines |
| WiFi zone code | `currentLocationFromWifiName:` at GLManager.m:1989, storage keys at :2018–2030, usage at :1614 |
| PR #180 | 7 files +523/−46, **CONFLICTING** (yniverz) |
| PR #190 | **9 files +544/−3** (bigger than prior plan said) — new 424-line `CustomHeadersViewController`, storyboard, GLManager, SceneDelegate, pbxproj. MERGEABLE |
| PRs #193/#187/#195 | README-only, MERGEABLE, trivial |

## Decisions locked in (resolving open questions)

1. **Min deployment: iOS 17.0** (project + target + Podfile). Unlocks `CLLocationUpdate.liveUpdates()`, `CLBackgroundActivitySession`, `CLMonitor`.
2. **Liquid Glass behind `if #available(iOS 26, *)`** with `.ultraThinMaterial` / `.borderedProminent` fallbacks.
3. **PR #190: accept after #180**, pending security review of header storage (no secret logging).
4. **Issue #188 (OwnTracks crash): fix before UI overhaul** — real crash affecting users.
5. **StoreKit: keep v1 for Tip Jar restyle.** StoreKit 2 migration = separate follow-up.
6. **simctl-first automation.** `xcrun simctl` covers boot/install/launch/screenshot/set-location natively. IDB (`brew install facebook/fb/idb-companion`) attempted for UI *taps* only, with fallback if it lags Xcode 27 beta (likely).

## Code style rules (mandatory)

Match GLManager.m / TrackingViewController.m exactly:
- `#pragma mark -` sections (Obj-C), `// MARK:` (Swift). No other organizational comments.
- Terse names (`loc`, `_httpClient`). No comments restating what code does.
- `static NSString *const` keys, NSUserDefaults directly. No wrappers, no protocols with one conformer, no Coordinator/Router, no Combine around delegate callbacks.
- Swift: one file per screen, flat `Form`/`Section` views, `@AppStorage` for defaults-backed settings, no ViewModel classes unless state is genuinely shared.

---

## Phase 0 — Link the fork
```bash
git remote rename origin upstream
git remote add origin git@github.com:SoPat712/Overland-iOS.git
git push -u origin main
```
Verify: `git remote -v`, `gh repo view SoPat712/Overland-iOS`.

## Phase 1 — Triage (report only; table in final summary)
Ranked verdicts on 5 PRs + 34 issues. Key: #180 accept+merge, #190 review→accept, #193/#187/#195 trivial README, #188/#197/#196 real bugs to fix, #151/#152 planned (Phase 4), #184/#171/#164 covered by #180.

## Phase 2 — Baseline build + automation
1. Bump deployment: Podfile `'11.0'`→`'17.0'`, pbxproj project-level `14.0`→`17.0` and target-level `15.0`→`17.0`.
2. `pod install` (regenerates xcconfig).
3. Build: `xcodebuild -workspace Overland.xcworkspace -scheme Overland -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
4. Boot `iPhone 17 Pro`, install, launch, screenshot via simctl. Optional: IDB companion if compatible with Xcode 27.

## Phase 3 — PR #180: review → rebase → merge
1. `git fetch upstream pull/180/head:pr-180 && git checkout pr-180`
2. Review checklist: discard filter off by default; slider↔segmented mapping round-trips; pause feature coexists with `pausesLocationUpdatesAutomatically` + trip mode; no personal endpoints/keys; storyboard diff minimal.
3. `git rebase main` — storyboard conflicts resolved minimally (replaced in Phase 5 anyway); keep GLManager logic intact.
4. Build + simulator smoke test (sliders persist, filter drops near-duplicates, pause/resume).
5. `git checkout main && git merge --no-ff pr-180` credit yniverz; push to fork.

## Phase 3.5 — Bug fixes (#188, #197, #196)
- **#188**: OwnTracks-mode crash on https+cert URLs — repro in simulator, guard the crash site.
- **#197**: `locations_in_payload` always 1 — audit the batch-send path; report count of *sent* points, not input-array count.
- **#196**: OwnTracks `tst` timestamp — verify point timestamp is used, not send-time.

## Phase 4 — Multiple WiFi zones (#151, considers #152)
- Storage: `WifiZones` key → array of dicts `{name, latitude, longitude[, bssid]}`. One-time migration from `WifiZoneName/Latitude/Longitude`.
- `currentLocationFromWifiName:` iterates zones (GLManager.m:1989).
- First Swift screen: `WifiZoneListView.swift` via `UIHostingController` from existing storyboard button. Add-sheet autofills current SSID + coords (same as today's modal). SSID-first matching, optional BSSID (entitlement already in Overland.entitlements).

## Phase 5 — SwiftUI + Liquid Glass overhaul
Keep GLManager/LOLDatabase Obj-C. Bridge with thin `@Observable GLManagerBridge`. Bridging header gains `#import "GLManager.h"`.
Order: 1) SettingsView (replace 466-line segmented-control wall) → 2) TrackingView (map + glass HUD + start/stop + send-now) → 3) Trip views → 4) EndpointView (URL validation) → 5) TipJar restyle (StoreKit 1) → 6) retire Main.storyboard for `@main` App. Screenshot-review each screen via simctl.

## Phase 6 — CoreLocation modernization
- **Adopt (iOS 17+)**: `CLLocationUpdate.liveUpdates(config)` async loop replacing delegate sprawl (stationary detection = free battery), `CLBackgroundActivitySession` for background reliability, `CLMonitor` for the pause/resume geofence (GLManager.m:1805–1835), `.fitness`/`.automotiveNavigation` LiveConfiguration mapped from existing activityType.
- **Skip**: `allowDeferredLocationUpdates` (deprecated), Kalman filters (scope creep).
- New `OverlandLocationEngine.swift`, `@objc`, feeds GLManager's existing queue. Keep delegate path compiling as fallback during transition. Battery claims need real-device validation; simulator = functional only.

## Phase 7 — Automation scripts (`ci_scripts/`)
simctl-based: `smoke_test.sh` (build→install→launch→screenshot→set location→screenshot), `test_tracking.sh`, `test_wifi_zone.sh`, `test_background_resume.sh`.

## Phase 8 — Wrap-up
README fork notes + screenshots, `AGENTS.md` (build/test commands, iOS 17 min, Xcode 27), push to fork, comment on upstream issues/PRs re: fork status. **Nothing pushed upstream without explicit user confirmation.**

## Risks
| Risk | Mitigation |
|------|------------|
| #180 storyboard conflicts | Minimal resolution; UI replaced in Phase 5 |
| AFNetworking/FMDB deprecation warnings on iOS 27 SDK | Monitor only; replace if they break |
| IDB incompatible with Xcode 27 beta | simctl covers 90% of needs; IDB optional |
| Deployment jump 15→17 | Watch for API availability errors; objc runtime fine |
| Liquid Glass iOS 26-only | `#available` + material fallbacks |
