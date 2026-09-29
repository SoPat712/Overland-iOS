# Battery and behavior audit

Reviewed September 29, 2026. Investigation only: no battery or backend fixes
were applied in this pass. The earlier, approved PR #180 follow-ups are included in this checkpoint.

## What is known

The [original report](https://github.com/aaronpk/Overland-iOS/pull/180#issuecomment-3447908515)
describes occasional heat, a frozen app, and battery loss near a stationary
stop on iPhone 15/iOS 18. It does not establish a cause. The author's
[September 20 follow-up](https://github.com/aaronpk/Overland-iOS/pull/180#issuecomment-5753628738)
explains notification and pause-setting changes and identifies a trip resume
concern, but does not report a confirmed fix for the heat/freeze issue.

This fork also contains a newer location engine, background sessions, and
SwiftUI polling that the original report did not test. A simulator UI pass
cannot measure the reported device battery problem.

Route replay, added after this investigation, copies each accepted upload
record into a separate 24-hour SQLite archive. That adds JSON serialization
and a local write per accepted point. Its 60 Hz playback timer runs only while
Play is active and stops when the app leaves the foreground or another tab opens.
The archive does not change Core Location settings, the send queue, or HTTP
requests. Its energy cost has not been measured on a device.

## Findings and proposed fixes

| ID | Evidence in this fork | Proposed change, pending approval | Settings and behavior impact |
| --- | --- | --- | --- |
| B-01 | `GLManager.processLocations:` clears `didPauseByRadius` and the dwell anchor before checking a callback's accuracy or age. In Both mode it calls `runEngineStandardUpdates` on every callback. The same delegate handles standard and significant updates. | Track explicit running/paused transitions and distinguish a legitimate resume from a delayed standard callback. Log transition reasons before choosing a resume rule. | Saved values need not change. Rejecting an accidental resume changes GPS restart timing, the dwell timer, and possibly the set of recorded points. It needs approval and device tests. |
| B-02 | The radius-stop block stops standard/live updates but does not end the `CLBackgroundActivitySession` created by `enableTracking`. Stop All, Off mode, and Significant mode do end it. | Scope the background session to the activity that needs it, paired with a reliable restart path. | No new preference is required. Background delivery and the location indicator can change, especially with When In Use permission. Simply adding `endBackgroundSession` at the stop point is not a safe standalone fix. |
| B-03 | The stationary anchor uses `lastLocation`, which advances only after distance, time, and accuracy filters. WiFi replacement happens before those filters. Rejected movement can leave the anchor stale. | Evaluate dwell/movement from a separately validated observation, without changing the points saved to the queue. Define WiFi-zone handling explicitly. | Settings values and payload format can stay intact. The meaning of the stop radius changes when filters reject points; pause timing and route gaps may change. This is a policy change. |
| B-04 | `GLManagerBridge` refreshes once per second and on activity notifications. The root reads up to 1,000 trip points on every bridge tick while Trip is selected. Polling is not gated by scene activity. | Suspend presentation polling while inactive and refresh on return; update route data only when it changes. | This can be confined to UI refresh behavior. It must not change the location source, stored settings, queue, or send cadence. No bridge changes are included in this UI pass. |
| B-05 | `scheduleLocalNotification` suppresses reminders whenever radius stopping is configured, even before an actual pause or during a trip. It also returns before canceling an existing reminder when notifications are off or radius stopping is configured. | Decide whether suppression should follow the actual paused state rather than the configured mode. Cancel obsolete reminders on the relevant transitions. | Changes which reminders appear, not location payloads. It is a notification behavior fix, not evidence of the heat/freeze cause. |
| B-06 | UI bridge setters clear incompatible pause settings. `updateSettingsFromResponse:` writes the Objective-C properties directly, so server responses can retain a radius plus automatic pause, or a radius outside Both mode. `stopsAutomaticallyActive` prevents using the radius then. | Decide whether to preserve the inactive stored value or normalize every entry point consistently. | This would change remote settings handling and potentially what a server's configuration response means. Do not include it silently in a battery fix. |

Repeated start calls alone do not prove a feedback loop. Apple explicitly says
repeated significant-monitoring starts do not automatically generate additional
events. Delayed callbacks, dwell resets, and service transitions need a trace
before attributing heat to them.

The presentation timer is another candidate to measure, not a confirmed cause.
iOS suspends timers with the app; lack of a scene-activity check does not prove
that polling runs continuously in the background.

## Existing changes that already affect settings

The approved PR follow-ups enforce these rules through the SwiftUI bridge:

- Turning on automatic pausing clears the stop radius.
- Choosing a positive stop radius turns off automatic pausing and clears the
  resume distance.
- Switching away from Both clears the stop radius.
- The radius-paused flag persists across relaunch and resets on the next
  nonempty callback while tracking is allowed, or on an explicit stop.

The broader fork predates this audit and includes tracking, queue, and network
changes as well as UI changes. It would be inaccurate to describe the entire
fork as UI-only. The original UI migration preserved the audited backend files;
the later replay feature adds a single capture call in `GLManager.processLocations:`.

## Dawarich, OwnTracks, and other receivers

A pause/resume repair does not require changes to endpoint URLs, credentials,
custom headers, HTTP requests, payload schemas, acknowledgments, or retries.
Those paths should remain outside the proposed battery patch.

The local send path uses a GeoJSON `locations` batch for Overland records and
a single `_type: location` object for OwnTracks records. Dawarich documents
separate endpoints for [Overland and OwnTracks](https://dawarich.app/docs/getting-started/track-your-location/).
The [OwnTracks HTTP contract](https://owntracks.org/booklet/tech/http/) remains
independent of how this app decides when to collect a location.

Server-visible behavior can still change. Fewer GPS observations mean fewer
points, longer gaps, later position updates, and potentially different trip
distances. `sendQueueIfTimeElapsed` runs from location-related events; the send
interval is not a periodic upload timer. Pausing can therefore delay uploads
even if the interval setting and all HTTP code remain unchanged. Manual sends
still use the existing queue path. Compatibility of the format is distinct
from freshness and completeness of the track.

Trip changes need separate review. Normal radius stopping is excluded during
an active trip in this fork, but trip startup disables significant-change
monitoring. Native automatic pause can end a trip and flush queued data.
Adding a trip wake-up source would change lifecycle behavior, so it is not an
incidental part of the proposed radius fix.

## Recommended sequence for approval

1. Add bounded diagnostic events for source start/stop, pause reason, callback
   age, session lifetime, and transition counts. Exclude coordinates, tokens,
   URLs, and payloads. Capture a real-device hang sample and energy trace near
   a radius stop before claiming a cause.
2. Review that evidence and agree on an exact resume policy. Apply B-01 only
   with tests for delayed/invalid callbacks, stop/start, relaunch, active trips,
   and remote settings. Do not alter accuracy, filters, radius, or send interval
   defaults to disguise the problem.
3. Evaluate B-02 with both Always and When In Use permissions on a physical
   device. Confirm background restart before changing session lifetime.
4. Discuss B-03, B-05, and B-06 individually; they change observable behavior.
   B-04 is a separate presentation optimization.
5. Re-run mocked GeoJSON/OwnTracks acknowledgment and queue-preservation tests,
   then compare physical-device route coverage and battery use under identical
   settings. Report measured results rather than promising a battery percentage.

## Apple references

- [CLBackgroundActivitySession](https://developer.apple.com/documentation/corelocation/clbackgroundactivitysession-4nl4y)
  explains its role in keeping a When In Use app eligible for background events.
- [Significant-change monitoring](https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges())
  documents cached initial events, relaunch, and the coarse delivery conditions.
  Those conditions do not provide Find My-like continuous freshness while
  standard updates are paused.

## Background execution and Live Activities

Investigation only. No new background modes, Live Activity, or keepalive settings
are enabled by this checkpoint.

The app already declares the `location` background mode. `GLManager.enableTracking`
retains a `CLBackgroundActivitySession` through `OverlandLocationEngine`; Off,
Significant-only, and explicit stop paths invalidate it. The radius-stop path
currently retains it (B-02). The Show Background Indicator setting controls
`CLLocationManager.showsBackgroundLocationIndicator`; it is separate from the
retained session. A persistent indicator is not evidence that the app is receiving
fresh fixes or sending them successfully.

Apple describes [CLBackgroundActivitySession](https://developer.apple.com/documentation/corelocation/clbackgroundactivitysession-4nl4y)
as a way to keep a When In Use app eligible for location events in the background.
Its [background-location guidance](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
still allows suspension and system termination. Correctly restoring location
services on a background launch matters more than trying to prevent every
suspension.

### Options

- **Visible Live Activity:** Apple presents this as an alternative way to support
  background location in [Discover streamlined location updates](https://developer.apple.com/videos/play/wwdc2023/10180/).
  It could show tracking status while the app is off-screen. Adding one alongside
  the existing session is not proven to improve reliability or save power.
- **Invisible or zero-width Live Activity:** there is no documented hidden
  keepalive API. Apple's [ActivityKit presentation guidance](https://developer.apple.com/videos/play/wwdc2023/10184/)
  requires the Lock Screen and Dynamic Island presentations and describes
  activities as visible, user-controlled status. A compact location icon is a
  reasonable design; deliberately empty content is not a dependable execution
  strategy.
- **Silent looping audio:** reject this for Overland. Apple's [background-mode
  reference](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
  defines the audio mode for audible playback, and [App Review guideline 2.5.4](https://developer.apple.com/app-store/review/guidelines/#software-requirements)
  limits background services to their intended purposes. An audio loop also adds
  work whose energy cost would need measurement. It does not repair a location
  lifecycle bug.
- **Scheduled background tasks:** useful for deferred work, not a reliable
  continuous-location or exact-send-interval mechanism. Apple notes that these
  tasks are not immediate in its [Live Activities Q&A](https://developer.apple.com/news/?id=qpqf1gru).

A Live Activity lasts at most eight active hours under the current
[ActivityKit documentation](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).
People can disable or dismiss it. Its extension cannot fetch location or make
network requests itself; the app supplies updates, or a server supplies ActivityKit
push notifications. Therefore an always-on tracker must continue to work when the
activity is unavailable or has ended.

### Proposed Settings option, pending approval

Add **Show Tracking Status** with a small location icon in the compact Dynamic
Island presentation. The Lock Screen view would show tracking state and the last
successful send time, without coordinates or a device identifier. Tapping it
would open Tracker. A default-on preference is reasonable only for this visible
status feature after the user starts tracking, with iOS authorization respected.

Use existing location/send events to update it, without a new polling timer or
APNs dependency. End it when tracking stops. Dismissing or expiring the activity
must not stop tracking, change presets, or rewrite server settings. Retain the
existing background session while evaluating the feature; replacing that session
would be a separate behavior change requiring approval and device tests.

This design requires an ActivityKit/WidgetKit extension and lifecycle handling.
It does not require changes to Dawarich or OwnTracks requests. Test denied Live
Activity permission, dismissal, expiry, locked-screen recording, process relaunch,
and battery use on a physical device before treating it as a reliability feature.
