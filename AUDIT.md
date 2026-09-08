# Modernization audit and issue coverage

Date: 2026-09-06. Branch: `backup/overhaul-2026-09-03`. Changes are local and uncommitted.
The recovered session explicitly requires owner review and trial before any commit or publication.

## Corrections made

### UI and settings

- Restored location permission status/actions and the shared resume-after-moving distance control.
  Starting tracking explicitly requests first-use location access.

- Slider getters now observe the bridge revision; dragging updates labels immediately. Tap the value
  for validated numeric entry. Single-unit steps avoid the old coarse presets; Off maps to the existing sentinel.
- The tab bar reserves safe-area space for controls while map backgrounds extend behind it and the status area. Offscreen pages cannot receive taps or VoiceOver focus.
  Tab selection still slides through the three pages; Reduce Motion disables page animation.
- Speed is a rounded white sign with an inset black border and white outer margin. It says Speed,
  not Speed Limit. The missing-server badge was unrelated and has been removed.
- Queued, Last Sent, location accuracy and age are visible. Send Now is disabled while sending,
  when the queue is empty, or when no endpoint exists. Start/Stop explicitly names tracking.
- Normal and trip settings share slider rows, formatting and grouped forms. Server configuration is
  pushed from Settings with native back navigation. Configuration status reflects saved settings, not a draft URL.
- Trip routes use stable database IDs and bounded fetches; scrubbing selects historical coordinates.
  All existing travel modes remain available. Inactive trips show zero duration/distance.
- WiFi zone deletion handles multiple rows in reverse order. Zone input validates coordinates and BSSID.

### Network and queue

- Empty OwnTracks queues never index a missing point. Each request keeps the exact sent keys and payload format,
  so changing logging mode or recording another point cannot make its callback remove unsent data.
- OwnTracks queues retain unsent locations; Only Latest remains the explicit queue-replacement mode.
- Request reentry is guarded. Background expiration cancels the task and invalidates stale callbacks.
  Reconfiguring the endpoint also invalidates the previous request before it can acknowledge a new batch.
- Last Sent is written only after acknowledgment. Attempt timing separately limits automatic retries.
  A missing previous send date permits the first automatic upload. Remote send_interval=off maps to -1.
- Successful HTTP responses can optionally acknowledge an upload without a JSON body. Otherwise
  a JSON object with result=ok is required. Malformed acknowledgments, geocodes and remote settings are guarded.
- Sent GeoJSON batches report their actual locations_in_payload. OwnTracks timestamps use the fix's Unix time;
  the battery percentage conversion no longer truncates before multiplication.
- Custom HTTP headers support the Server form, header_* setup URL parameters and custom_headers server responses.
  Names/values are validated; Authorization and transport-managed headers are reserved. Tokens/response bodies
  and endpoint URLs are not logged. Existing header-array preferences from PR #190 migrate when present.
- SQLite statements use UTF-8-safe preparation lengths and reset/finalize consistently. Preparation,
  statement, serialization and exception failures roll back their transactions, including prior deletions.
- Queue storage moves from purgeable Caches into Application Support using SQLite backup (including WAL state).
  Migration publishes the new file only after success; failure retains the source. The legacy cache file is retained
  as a migration fallback and is no longer the active queue after successful migration.
- Queue keys include UUID suffixes so distinct same-second records do not overwrite one another.

### Location and trip lifecycle

- Stops and delayed callbacks honor tracking state. Changing settings while stopped does not restart tracking.
  Region exits cannot reactivate a tracker explicitly stopped by the user.
- Trip points remain eligible when normal Update Mode is Off. Significant-change auto-stop is disabled during trips.
- The live-update task clears stale configuration on exit and uses a generation check so cancelled tasks cannot
  clear a newer task. Activity changes reach the active source. Custom accuracy and disabled automatic pausing
  use the CLLocationManager source rather than silently ignoring those settings.
- Stationary live-update events reach the existing pause/geofence/trip-ending behavior. Heading updates with no
  consumer were removed; background sessions end when standard tracking stops.
- Filters accept the first fix and compare subsequent fixes with the last accepted point in that batch.
  Invalid and out-of-order fixes are rejected. Trip points carry trip_mode with trip_id.
- Pedometer completion serializes trip writes/closing on main; duplicate trip-end requests are ignored.
  Trip completion restores prior tracking intent and clears the idle-timer override. Distance queries close their
  result set and update their cache; timeline queries fetch only the latest 1,000 records.
- Notification registration and reminder operations run on a serial queue, avoiding a synchronous notification
  service stall on the UI thread (observed on the iOS 27 test simulator).
- Cold-launch setup URLs are handled, invalid endpoint URLs are rejected, and quick-action completion handlers run.

## GitHub coverage

These are local implementation statuses, not claims that GitHub items were closed.

| Upstream item | Local result |
| --- | --- |
| [PR #180](https://github.com/aaronpk/Overland-iOS/pull/180), yniverz | Already merged in local history; precision/filter/pause changes re-audited. Two old mapping errors had already been fixed. |
| [#184](https://github.com/aaronpk/Overland-iOS/issues/184) | Fine distance control with one-meter increments and direct entry. |
| [#164](https://github.com/aaronpk/Overland-iOS/issues/164) | Stationary pause controls retained; real movement/background behavior still needs a device trial. |
| [#188](https://github.com/aaronpk/Overland-iOS/issues/188) | Empty OwnTracks send crash guarded, plus malformed-response and queue-preservation fixes. |
| [#196](https://github.com/aaronpk/Overland-iOS/issues/196) | OwnTracks tst is the fix timestamp in Unix seconds. |
| [#197](https://github.com/aaronpk/Overland-iOS/issues/197) | Actual sent batch count is written to locations_in_payload. |
| [#151](https://github.com/aaronpk/Overland-iOS/issues/151), [#152](https://github.com/aaronpk/Overland-iOS/issues/152) | Multiple WiFi zones and BSSID disambiguation; device entitlement/SSID availability remain prerequisites. |
| [PR #190](https://github.com/aaronpk/Overland-iOS/pull/190), Rubeanie; [#189](https://github.com/aaronpk/Overland-iOS/issues/189) | Custom-header capability adapted to SwiftUI and current request handling; PR itself not merged. |
| [PR #193](https://github.com/aaronpk/Overland-iOS/pull/193), dietrichmax | Colota Android integration link applied locally. |
| [PR #187](https://github.com/aaronpk/Overland-iOS/pull/187), calebgab | Reitti listing applied locally. |
| [PR #195](https://github.com/aaronpk/Overland-iOS/pull/195), weltspion | Geomanic listing applied locally. |
| [#170](https://github.com/aaronpk/Overland-iOS/issues/170) | Active-trip GeoJSON points include trip_mode. |
| [#144](https://github.com/aaronpk/Overland-iOS/issues/144) | Partial: current-trip route and recent-point timeline; not a persistent all-day route viewer. |
| [#185](https://github.com/aaronpk/Overland-iOS/issues/185) | Partial: last 50 outcome indicators for the current process; not a persistent HTTP log/export. |
| [#178](https://github.com/aaronpk/Overland-iOS/issues/178) | Partial: header_* URL configuration, not every possible setting. |
| [#171](https://github.com/aaronpk/Overland-iOS/issues/171) | Not implemented: accuracy filtering does not provide altitude/velocity-presence toggles. The old plan incorrectly equated them. |

The other open upstream requests (MDM, localization, Watch, iBeacons, Live Activities, iCloud,
location push, shortcuts, automation, notifications and platform questions) are not silently marked complete.

## Verification

- Final Xcode 27 / iOS 27 simulator app build passed on 2026-09-06.
- IDB verified Tracker controls above the tab bar; Desired Accuracy drag updated 100 → 1275 m;
  numeric editor accepted 100 and restored the displayed value.
- Regression suite: 21 tests passed with no failures on the isolated Overland Regression simulator.
- Prior IDB interaction checks passed: controls clear the tab bar, Trip Settings and Server navigation,
  numeric entry and restoration. The final permission and resume-distance UI additions await owner trial.
- Final build installed and launched on the owner's iPhone 17 Pro simulator. No further screenshot
  captures or visual automation were performed after the owner requested manual testing.

The standalone test simulator is named Overland Regression. Its data is independent of the owner's
normal iPhone 17 Pro trial simulator. The tests inject an in-memory queue and intercept requests to
https://overland.test; they do not upload to a real endpoint.

## Owner trial checklist

Use the installed Overland app on the iPhone 17 Pro simulator. No screenshots are needed;
report the screen, action, expected result and actual result if anything fails.

1. **Tracker layout:** Check the speed sign has a thin white edge outside its black border.
   Confirm the map fills the screen behind the status area and glass tab bar, with no white strips.
   Confirm Start/Stop and Send Now stay above the tabs. Switch all three tabs and return.
2. **Permissions:** In Settings, check Location Access. Allow access if requested; background
   testing needs Always in iOS Settings. Start Tracking, then supply a location using Device Hub
   or `xcrun simctl location 77CE069B-898E-4372-A534-353906404362 set 45.5152,-122.6784`.
   Confirm location/age update and the queue grows. Stop Tracking when done.
3. **Settings:** Drag Desired Accuracy and watch its value update. Tap a value, enter an exact
   number, save, leave the page and return. Check Off values and canceling edits. Restore your
   preferred settings. With automatic pausing enabled, check Resume After Moving is available.
4. **Server:** Configure your endpoint/token and any required headers. Save, return and reopen
   to confirm persistence. With queued points, tap Send Now. An acknowledged upload should
   reduce the queue and update Last Sent. A rejected upload should retain queued points.
5. **Trip:** Start a trip, change the simulated location several times, and check the route,
   distance and timeline. Scrub an older point, then return to live. End the trip and confirm
   the earlier tracking state is restored. Open Trip Settings and check exact-value editing.
6. **On a real device later:** Verify recording with the screen locked, pause/resume after
   movement, WiFi zones and battery use. Simulator tests cannot establish those behaviors.

Publication remains pending your explicit approval after this trial.

Final layout correction: full-screen map backgrounds with safe-area-inset tab controls; clean build repeated after this change. Visual confirmation is assigned to the owner, without further screenshots.

Map layout follow-up: map-aware bottom insets raise system attribution above the HUD. Each navigation
root reserves the measured glass-tab-bar height. IDB accessibility confirms a 402 × 874 full-screen
map, Legal at y=485, tracking controls ending at y=761, and tabs starting at y=776. No screenshot was
captured. Removed the redundant Trip navigation title while retaining its settings button.

Final navigation verification: shared measured tab-bar clearance is applied inside each root screen
and each pushed settings destination, because applying it outside NavigationStack loses the inset.
IDB confirmed Tracker buttons end at y=761 before tabs at y=776; Server's Clear Server URL row
ends at y=745 before the same tabs. Removed Trip, Settings-root and Server headings as requested;
Server retains its Back button. Build passed; checks used accessibility data without screenshots.
The requested top-left native Maps attribution placement remains unimplemented: the public MapKit
interface provides no attribution alignment control. Native attribution remains above the bottom HUD,
using the safe-area-inset approach described in Apple's Meet MapKit for SwiftUI (WWDC23, 10043).

## Usage presets and source-linked help (2026-09-07)

- Added High Resolution, Low Power, Balanced, Walking / Running and Driving at the top of Settings.
  These are tracking-use profiles based on the README, not server connection templates. Concrete
  Balanced thresholds and activity-specific variants are labeled as Overland recommendations.
- GLManager writes the profile settings together, removes stale resume monitoring, and refreshes an
  enabled tracker once. Applying does not enable a stopped tracker and is rejected during a trip.
- Profile recognition compares the controlled settings; manual edits show Custom. Upload settings,
  credentials, queued points and trip-specific preferences are preserved. Resume distance is shared
  and is explicitly identified as changing in the UI.
- Section info buttons explain settings, with links to the supplied Apple documentation and README.
  Help covers permissions, tracking modes, accuracy and saved-point filters, stationary behavior,
  logging/sending, background indicator, WiFi, server settings and trip overrides.
- No exact update cadence or measured battery savings are promised. Removed the README's unverified
  80% battery-saving claim. The Apple forum answer is labeled as configuration-specific guidance.
- App build passed. All 25 isolated regression tests passed, including four new preset cases.
  The final follow-up changed explanatory copy only; no core code changed after the passing suite.

Trial: open Settings, choose a Usage Preset, and tap a section's info icon. Changing a covered setting
should switch the preset to Custom. Applying a preset changes tracking preferences immediately;
restore your preferred values after trying them.

Final preset UI check: IDB opened Settings, found the Usage Preset selector, opened About Usage
Presets, verified the explanation and README source link, then dismissed the sheet. No preset or
user preference was changed. Final build installed on iPhone 17 Pro; no screenshots captured.

## Current-location marker and stop confirmation

- Tracker and Trip use a custom MapKit UserAnnotation with a blue dot and a decorative expanding ring.
  The marker follows MapKit's location; it does not invent a position before a fix exists. The ring is
  not an accuracy radius. Animation is disabled for Reduce Motion, Low Power Mode, inactive scenes
  and offscreen map tabs.
- Stopping from Tracker or the Settings toggle now uses an alert with Stop Tracking and Keep Tracking.
  The first fake-data run found that confirmationDialog hid its cancel choice on this simulator;
  switching to alert made the explicit Keep Tracking action available and its cancellation passed.
- Fake-data testing uses one disposable simulator and a localhost receiver. The test refuses to start
  alongside another booted simulator. Screenshots are not captured. End-to-end results follow below.

## Fake-data verification (2026-09-08)

One disposable iPhone 17 Pro simulator was booted at a time. The end-to-end script passed:

- Main stop alert: Keep Tracking canceled the stop and tracking remained enabled.
- A simulated multi-waypoint route delivered at least six distinct coordinates.
- The localhost receiver rejected the first upload with HTTP 503; a later successful retry retained
  the same records, so the queue did not lose data.
- Trip metadata and the live timeline were present, and the current-location annotation was exposed.
- Ending the trip restored the earlier tracking state; confirming Stop Tracking stopped it.
- The disposable simulator was removed before reopening the owner's trial simulator.

The separate named Overland Regression simulator was also removed during simulator cleanup. The
post-marker 25-test suite therefore was not rerun to honor the one-booted-simulator limit; the prior
25-test run remains valid for the Objective-C/core changes, and this fake route covers the new UI and
runtime path. The final app build passed after the location marker and alert changes.

Trial simulator follow-up (2026-09-08): set 45.5152,-122.6784 with simctl, started tracking,
received and displayed the fix at ±5 m, age 0:19, and queue count 1. Opened the stop alert and
verified both accessible actions; Keep Tracking dismissed it while Stop Tracking remained visible.
Only the trial simulator is booted now. No screenshots captured.
