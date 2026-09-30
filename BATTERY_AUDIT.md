# Battery and behavior audit

Reviewed September 29, 2026. Findings B-01 through B-06 remain proposals.
The approved PR #180 follow-ups are included. The separately requested background
runtime helpers are described below; they do not implement the battery repairs.

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

The owner authorized the following additions after this audit. Existing location
sessions remain unchanged. `OverlandBackgroundRuntime` observes tracking,
settings, authorization, send completion, and reminder changes. It controls an
ActivityKit extension and an optional audio session. Neither helper rewrites
tracking preferences, restarts a paused location engine, or participates in HTTP.

### Live Activity

Tracking Live Activity defaults on with a compact location icon. Status adds the
last successful send time to the expanded Dynamic Island; Blank supplies
zero-sized content. Normal Lock Screen content is empty and transparent. iOS
still controls the surface and may reserve space. No documented API restricts an
activity to the Dynamic Island.

The activity's `staleDate` comes from the pending notification whose identifier
is `reminder`. When that deadline passes, the widget uses `context.isStale` to
show the existing message: "Location updates were stopped. Launch the app to
resume." Tapping the activity opens Tracker. Successful reminder scheduling and
cancellation publish an observation event; the runtime reads the actual pending
request rather than maintaining a second ten-minute timer. The original
notification and its settings, throttling, and suppression rules remain intact.
In particular, the suppression issue in B-05 is not repaired by this feature.

A missed reminder deadline cannot distinguish a killed app from suspension,
missing fixes, or another collection problem. It does not detect network loss.
The stale presentation can be rendered by iOS without executing the app, but
rendering time is not an exact alarm. No visible warning is possible once the
activity has ended or been dismissed.

Creation is restricted to the foreground. Existing activities are adopted on
relaunch; stopping tracking, losing location access, or disabling the option ends
them. Expiry and dismissal do not trigger a background restart loop. Reopening
Overland or pressing Retry requests another activity. Send-time updates are
limited to one per thirty seconds; appearance, trip, and reminder-deadline
changes apply immediately. There is no activity polling timer or APNs dependency.

### Silent audio

Silent Audio is an experimental, default-off option. `SilentAudioSession` creates
a one-second PCM buffer of zeros and loops it with `AVAudioPlayer`, using the
playback category and mixing with other apps. A serial background queue owns
audio-session and player calls so they do not block the main thread. It uses no microphone. Stopping
tracking or losing location access stops playback and releases the audio session.
Interruption handling honors the system's resume indication; explicit Retry can
recover from a missing interruption-ended event. There is no periodic retry loop.

[StikDebug uses silent audio](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Services/BackgroundAudioManager.swift)
with a different audio-engine implementation. Its source is AGPL-3.0; no code or
assets were copied into Overland. Overland's implementation uses Apple's public
audio APIs. SuperAlarm's claimed zero-content implementation was not verified
from public source.

Apple's [background-mode reference](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
describes audio mode for audible playback, and [App Review guideline 2.5.4](https://developer.apple.com/app-store/review/guidelines/#software-requirements)
limits background services to their intended purposes. Silent keepalive may not
meet App Store review requirements. Its battery cost has not been measured.

### Platform limits and validation

Apple describes a Live Activity or `CLBackgroundActivitySession` as support for
background location in [Discover streamlined location updates](https://developer.apple.com/videos/play/wwdc2023/10180/).
Overland already retains the latter. Its [background-location guidance](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
still allows suspension and system termination. Adding helpers alongside that
session is not evidence of improved reliability.

[ActivityKit documentation](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
limits an activity to eight active hours. People can dismiss or disable it, and
its extension cannot fetch location or make network requests. None of these
helpers bypass force-quit or permissions.

Physical-device validation remains necessary for locked-screen routes, calls,
other audio playback, process termination, activity expiry/dismissal, and energy
use. Compare route coverage and battery use with identical tracking settings and
helpers individually enabled. Simulator lifecycle tests cannot establish battery
savings or continuous background delivery.

Simulator checks passed for audio start/stop, interruption resume, explicit retry,
and Live Activity creation, appearance changes, and cleanup when tracking stops.
The 25 existing queue, HTTP, settings, and location regressions also passed.
Accessibility-driven app checks verified the appearance selector, audio gating,
start/stop cleanup, stop confirmation, and the Tracker deep link without screenshots.
The system-reminder integration check remains unverified: on this iOS 27
simulator, notification calls stalled inside `usernotificationsd` while it waited
for its notification-settings service. Restarting the disposable simulator did
not clear that wait. The opt-in test remains in `BackgroundRuntimeTests.swift`
for an environment with a responding notification service. No screenshot or
simulator result establishes the real-device appearance or battery benefit.
