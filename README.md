Overland GPS Tracker for iOS
============================

Overland records your location in the background and sends it to a server you
choose. Records can include GPS coordinates, motion state, steps, and battery
level. The app keeps data locally while offline and uploads it in batches when
a connection is available.

You can use an existing backend or build an HTTP receiver. Supported services
and integrations include:

* [Compass](https://github.com/aaronpk/Compass) - a self-hosted PHP app for storing and reviewing Overland data
* [Wayfinder](https://github.com/dontic/wayfinder) - a self-hosted app for Overland
* [Dawarich](https://dawarich.app/) - a self-hosted alternative to Google Location History
* [Reitti](https://www.dedicatedcode.com/projects/reitti/) - self-hosted location tracking and analysis
* [PureTrack](https://puretrack.io/add-overland) - tracking for lightweight planes and gliders
* [Open Humans](https://overland.openhumans.org/) - location recording and data sharing for research
* [Icecondor](https://icecondor.com/) - location sharing and geofence alerts
* [Geomanic](https://geomanic.com/) - a hosted trip tracking service
* [Home Assistant](https://www.home-assistant.io/) - integration through its [OwnTracks](https://www.home-assistant.io/integrations/owntracks/) support

For Android, see [Colota](https://github.com/dietrichmax/colota) and its
[Overland integration](https://colota.app/docs/integrations/overland).

## About this fork

This fork uses SwiftUI screens inside a native UIKit tab controller, with Liquid
Glass on iOS 26 and later and material backgrounds on earlier versions. It
requires iOS 17.

Tracker and Trip share a map with a draggable panel behind the native tab bar.
Drag the handle above the tabs to expand or collapse the controls. The panel
fits its contents; on small screens or with large text, it stops at the available
height and lets you scroll. Settings has its own page without a map. Sliders
support exact numeric entry.

UIKit handles tab selection, drag gestures, icons, and labels. The panel uses
regular `UIGlassEffect` on iOS 26 and later, with a material fallback on older
versions. The tabs stay in place as the panel resizes.

The fork includes PR #180's precision controls, accuracy filter, and stationary
stopping, plus its later notification, persisted pause-state, and safe-settings
follow-ups. It also adds multiple WiFi zones with optional BSSID matching,
custom HTTP headers, server-certificate diagnostics, and the last 50 send
outcomes for the current app session.

Queue and networking fixes address empty OwnTracks sends, incorrect timestamps,
and batch counts. The location source preserves custom accuracy and pause
settings. Background reliability and battery use still need real-device testing.

See [AGENTS.md](AGENTS.md) for build commands and [BATTERY_AUDIT.md](BATTERY_AUDIT.md)
for unresolved background-tracking findings. Battery improvements require device
measurements; simulator checks do not establish energy savings.

## Background runtime options

Settings → Background Runtime adds two helpers that follow Start/Stop Tracking:

- **Tracking Live Activity** defaults to Minimal, a location icon in the Dynamic
  Island. Status also shows the last successful send in the expanded view.
  Blank requests zero-sized content. Normal Lock Screen content is transparent
  and empty; iOS may still reserve a surface. There is no documented switch to
  restrict a Live Activity to the Dynamic Island.
- **Silent Audio (Experimental)** defaults off. It loops digital silence through
  the audio playback session and mixes with other audio. Calls can interrupt it.
  If playback remains paused afterward, use Retry Background Helpers. It uses no
  microphone and may increase battery use.

The Live Activity uses the deadline of Overland's existing ten-minute location
reminder. If that deadline passes, it shows the same request to open Overland;
tapping it opens Tracker. Rescheduling or canceling the reminder updates the
activity's deadline. The existing notification remains enabled by its own setting.
This is a missed-update warning, not proof that the app was killed or the server
is offline. The reminder's current suppression rules still apply, including
suppression when stationary stopping is configured.

Activities can be dismissed or disabled, and expire after at most eight active
hours. Open Overland or use Retry Background Helpers to request another. The
app cannot update an ended activity after it has been killed; iOS controls when
it renders the warning from the previously supplied deadline.

These helpers require tracking to be enabled with location access and an active
tracking mode, visits, or a trip. They leave Core Location settings, stationary
pausing, the upload queue, server payloads, and the existing background-location
session intact. They do not guarantee continuous execution or bypass force-quit.
Apple documents background audio for audible playback, so a silent keepalive may
not meet App Store review requirements. See [BATTERY_AUDIT.md](BATTERY_AUDIT.md)
for sources and the remaining device tests.

## Documentation

### Tracker screen

Start Tracking begins location collection. Stop Tracking asks for confirmation;
Keep Tracking dismisses the alert without stopping. The map follows your location
until you pan it. The vertical pill at the top right contains map-style and
recenter controls. Tap Show My Location to follow again.

The current-location dot pulses while the app is active. Reduce Motion and
Low Power Mode disable the animation. The halo is decorative; it does not
measure location accuracy.

* `Updated` shows the time since the last accepted location point.
* `Current location` shows its coordinates and reported horizontal accuracy.
* `Speed` shows the most recent speed at the top left.
* `Queued` counts records waiting to be sent.
* `Last Sent` shows the time since the last acknowledged upload.
* `Send Now` uploads queued data immediately.
* `Send Every` sets the automatic send interval. The slider covers 0–3600 seconds;
  0 means Off. Tap the value to enter an exact number. Off leaves data queued for
  manual sending or a later automatic upload. Longer intervals reduce the number
  of network requests.

The ruler at the top of the Tracker panel keeps the selected tick in the center.
Older points lie to its left and **Live** lies to its right. Drag right to browse
older points, or left to return to Live. A tap alone does not change modes.
Each tick selects one recorded point; the step buttons also move one point at a
time. Play follows the time between fixes
at 1×, 5×, 10×, 20×, or 50× recorded time. The marker and camera move between
fixes; this straight-line interpolation is for display only. The map shows the
traveled route in blue and the remaining route as a dashed teal line. The details
and replay speedometer show the last logged point's values, and **View upload
record** shows its complete GeoJSON or OwnTracks JSON. A queued record is not
proof of delivery.

Replay keeps a separate local copy of accepted location records for 24 hours,
including points removed from the send queue after upload. Collection starts
with this app version; previously sent points cannot be recovered. The history
does not change tracking settings, upload timing, or server requests. Existing
replay stores migrate in place; record IDs remain unique after old points expire.

MapKit's Apple Maps credit and Legal link stay on the map, just above the glass
panel as it expands or folds. [Apple's Maps guidance](https://developer.apple.com/design/human-interface-guidelines/maps)
calls for both to remain visible with the map. MapKit reframes map content as
that clearance changes.

Trip uses the same map and preserves its position when you switch tabs.
Choose a travel mode and tap Start Trip to record a route. The panel shows
distance, duration, and a timeline of the latest 1,000 points. Select a point to
inspect it, or tap Live to return to your location. Stop Trip writes a trip record
for upload alongside the location points. The map pill also opens Trip Settings
on a separate page. Tap Trip to return to the map and its recenter control.

### Settings

Open Settings from the bottom bar. Its form fills the page and scrolls above
the tabs.
The Usage Preset selector applies a set of tracking preferences. Section info
buttons explain the controls and link to their sources.

* `Server` sets the endpoint, access token, device ID, custom headers, and
  acknowledgment policy.
* `Tracking Enabled` starts or stops location collection. Stopping preserves
  queued records.
* `Location Access` shows iOS permission status. Use the access buttons when
  available, or open iOS Settings to change permission and Precise Location.

**Location updates**

These controls configure [Core Location](https://developer.apple.com/reference/corelocation):

* `Update Mode` selects Standard, Significant, Both, or Off. Standard requests
  regular updates for detailed routes. Significant uses
  [significant-change monitoring](https://developer.apple.com/reference/corelocation/cllocationmanager/1423531-startmonitoringsignificantlocati)
  for coarse movement history. Both enables both sources. Off disables those
  sources; visit tracking is separate. iOS controls when updates arrive.
* `Visit Tracking` records iOS-detected arrivals and departures. Events can arrive
  after the visit occurred.
* `Accuracy Preset` selects Custom, Best, or Navigation. Custom exposes
  `Desired Accuracy` in meters. A smaller value requests more precision and can
  require more time and power; it does not guarantee the accuracy of a fix.
  See Apple's [desiredAccuracy](https://developer.apple.com/reference/corelocation/cllocationmanager/1423836-desiredaccuracy) reference.
* `Activity Type` describes the expected movement to iOS and helps it decide when
  to pause. It does not label the trip or classify recorded motion.
  See [activityType](https://developer.apple.com/reference/corelocation/cllocationmanager/1620567-activitytype).
* `Show Background Indicator` requests the system's visible location indicator.
  It does not grant permission or keep the app running unconditionally. The
  linked [Apple forum guidance](https://developer.apple.com/forums/thread/726945)
  discusses its effect in a particular background-tracking configuration.
* `Pause Updates Automatically` lets iOS pause standard updates. Resume timing
  depends on iOS and the enabled services; it is not immediate or guaranteed.
* `Resume After Moving` creates an exit region around the last fix after an
  automatic pause. Leaving that region can resume an enabled tracker.
  The distance is shared with trip settings.

**Recording and sending**

* `Logging Mode` controls storage and payload format. All Data queues GeoJSON
  records. Only Latest replaces queued location data with the latest fix.
  OwnTracks retains unsent fixes and sends one OwnTracks record per request.
* `Locations per Batch` limits records in each GeoJSON request. Smaller batches
  produce smaller requests; larger batches clear a backlog with fewer requests.
  It does not change the send interval.
* `Min Distance Between Points` discards fixes closer than the selected distance
  to the last accepted point.
* `Min Time Between Points` discards fixes received too soon after the last
  accepted point.
* `Max Accuracy of Points` rejects fixes whose horizontal uncertainty exceeds
  the threshold. A 10 m limit accepts reported uncertainty of 10 m or less.
  Lower values can leave gaps when reception is poor.
* `Stop Within Radius` and `Stop After` pause standard updates when accepted
  fixes remain within the radius for the configured time. They apply to normal
  Both mode, not an active trip. Significant-change monitoring continues and can
  restart standard updates after movement. The delay may leave a gap in the route.
* `Notifications` controls local tracking and send notifications. iOS notification
  permission is also required.
* `WiFi Zones` assigns fixed coordinates to a network name. BSSID can distinguish
  access points with the same name. Matching requires iOS to expose network identity.

Distance, time, and accuracy filters act on points after iOS delivers them.
They do not set the GPS sampling rate. Set a filter to Off to disable it.

#### Trip settings

Trip settings override the normal accuracy, activity, logging, batch, filter,
indicator, and pausing settings while a trip runs. Ending the trip restores
the earlier tracking state. The resume distance is shared with normal tracking.

Automatic pausing can end a trip. Leave it off if you want to end trips manually.
Prevent Screen Lock keeps the display awake during a trip and increases display
power use; it does not guarantee background execution.

#### System settings

Some preferences also appear in the iOS Settings app:

* `Include tracking stats` includes diagnostic metadata about visits and the
  app lifecycle.
* `Consider HTTP 2XX Successful` accepts any successful 2xx response as an upload
  acknowledgment, including an empty body. Otherwise the server must return
  `{"result":"ok"}`. An acknowledgment removes the sent records.
* `Include Unique ID in Logs` includes the device's vendor identifier. Device ID
  is a separate, user-defined field.
* `Precise Settings` belongs to the legacy interface. The SwiftUI controls always
  provide sliders and numeric entry.

#### Configuration by custom URL

A setup link opens Overland and saves the endpoint, token, device ID, and
unique-ID preference:

```
overland://setup?url=https%3A%2F%2Fexample.com%2Fapi&token=1234&device_id=1&unique_id=yes
```

Query parameters:

* `url` - the receiving HTTP(S) endpoint
* `token` - the access token
* `device_id` - the user-defined device identifier
* `unique_id=yes` - enable the vendor identifier in supported records

### Usage profiles

Choose a profile for the detail you need. These are starting points; test
background behavior and battery use on your device.

#### High resolution tracking

* Pause Updates Automatically: Off
* Resume with Geofence: Off
* Tracking Mode: Standard
* Activity Type: Other
* Desired Accuracy: Best

This configuration requests detailed routes and keeps standard updates active.
It can use more power than coarse tracking. iOS still controls delivery, so
one point per second is not guaranteed.

#### Battery saving / low resolution

* Pause Updates Automatically: On
* Resume with Geofence: 500m
* Tracking Mode: Significant Location
* Activity Type: Other
* Desired Accuracy: 100m

Significant-change monitoring suits neighborhood-scale history rather than
detailed routes. The stored accuracy and pause settings apply to standard
updates; they do not control the significant-change service.

#### Battery saving / high resolution

* Tracking Mode: Both
* Activity Type: Other
* Stop Updates if within Radius: >10m
* Stop Updates after: <5m

This combines standard updates while moving with significant-change monitoring
while stationary. Resume timing depends on iOS. Neither an exact resume distance
nor a battery-saving percentage has been established for this fork.

## Configuration guide

The presets in Settings apply these values:

| Preset | Mode | Accuracy | Activity | Pausing / resume | Stationary stop |
| --- | --- | --- | --- | --- | --- |
| High Resolution | Standard | Best | Other | Off / Off | Off |
| Low Power | Significant | 100 m stored; ignored by significant-change service | Other | On / 500 m | Off |
| Balanced | Both | 100 m | Other | Off / Off | 50 m for 180 s |
| Walking / Running | Standard | Best | Fitness | Off / Off | Off |
| Driving | Standard | Navigation | Automotive | Off / Off | Off |

All presets disable saved-point filters and visit tracking. The background
indicator is on except in Low Power. Each stores Stop After as 180 seconds;
it takes effect only when the stationary radius is enabled.

Presets leave server credentials, logging format, send interval, batch size,
trip-specific settings, and queued records unchanged. They change the resume
distance, which is shared with trips. Applying one does not start tracking.
Finish an active trip before selecting a preset. Editing a setting covered by
the preset changes the selector to Custom.

The first three presets adapt the usage profiles above. Balanced's 50 m / 180 s
thresholds and the Walking / Running and Driving variants are Overland choices.
They are not Apple-provided presets.

Automatic sends are checked when location updates arrive, not on an exact
background timer. A server acknowledgment removes only the records sent in that
request. Configured means a server URL is saved; it does not verify connectivity.
Recent Sends keeps up to 50 outcomes and resets when the app restarts.

Sources: [Apple desired accuracy](https://developer.apple.com/documentation/corelocation/cllocationmanager/desiredaccuracy),
[activity type](https://developer.apple.com/documentation/corelocation/cllocationmanager/activitytype),
[significant-change monitoring](https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges()),
[Core Location](https://developer.apple.com/documentation/corelocation), and
[Apple engineer's iOS 16.4 background guidance](https://developer.apple.com/forums/thread/726945).
The forum advice applies to a particular configuration. Queueing, filtering, and
trip overrides described here are behavior implemented by this fork.

## API

Overland posts location data to the configured endpoint.

Endpoint URL templates use values from the most recent location update:

* `%TS` - Timestamp (ISO 8601, e.g. `2023-12-05T16:50:25Z`)
* `%LAT` - Latitude
* `%LON` - Longitude
* `%SPD` - Speed in meters per second (negative means invalid)
* `%ACC` - Accuracy (horizontal) of location in meters
* `%ALT` - Altitude in meters
* `%BAT` - Battery percent (e.g. `0.8` for 80%)

For example, you can use the URL below to receive all the data in the query string:

```
https://example.com/input?ts=%TS&lat=%LAT&lon=%LON&acc=%ACC&spd=%SPD&bat=%BAT&alt=%ALT
```

The POST request body will be a JSON object containing a property `locations` which is an array of GeoJSON objects. The default batch size is 200 but can be set in the settings. This request will look something like the following:

```
POST /api HTTP/1.1
Authorization: Bearer xxxxxx
Content-Type: application/json

{
  "locations": [
    {
      "type": "Feature",
      "geometry": {
        "type": "Point",
        "coordinates": [
          -122.030581, 
          37.331800
        ]
      },
      "properties": {
        "timestamp": "2015-10-01T08:00:00-0700",
        "altitude": 0,
        "speed": 4,
        "horizontal_accuracy": 30,
        "vertical_accuracy": -1,
        "motion": ["driving","stationary"],
        "pauses": false,
        "activity": "other_navigation",
        "desired_accuracy": 100,
        "deferred": 1000,
        "significant_change": "disabled",
        "locations_in_payload": 1,
        "battery_state": "charging",
        "battery_level": 0.80,
        "device_id": "",
        "wifi": ""
      }
    }
  ],
  "current": { ... }, (optional)
  "trip": { ... } (optional)
}
```

If you've configured an access token, it will be sent in the HTTP `Authorization` header preceded by the text `Bearer`.

The properties on the `location` objects are as follows:

* `timestamp` - the ISO8601 timestamp of the `CLLocation` object recorded
* `altitude` - the altitude of the location in meters
* `speed` - meters per second
* `course` - direction of travel in degrees
* `horizontal_accuracy` - accuracy of the position in meters
* `vertical_accuracy` - accuracy of the altitude in meters
* `speed_accuracy` - accuracy of the speed in meters per second, or -1 if speed is unknown
* `course_accuracy` - accuracy of the course in degrees, or -1 if speed is unknown
* `motion` - an array of motion states detected by the motion coprocessor. Possible values are: `driving`, `walking`, `running`, `cycling`, `stationary`. A common combination is `driving` and `stationary` when the phone is resting on the dashboard of a moving car.
* `battery_state` - `unknown`, `charging`, `full`, `unplugged`
* `battery_level` - a value from 0 to 1 indicating the percent battery remaining
* `wifi` - If the device is connected to a wifi hotspot, the name of the SSID will be included
* `device_id` - The device ID configured in the settings, or an empty string
* `unique_id` - If "Unique ID" is enabled, the device's Unique ID as set by Apple

The following properties are included only if the "Include Tracking Stats" option is selected:

* `pauses` - boolean, whether the "pause updates automatically" preference is checked
* `activity` - a string denoting the type of activity as indicated by the setting. Possible values are `automotive_navigation`, `fitness`, `other_navigation` and `other`. This can be set on the settings screen.
* `desired_accuracy` - the requested accuracy in meters as configured on the settings screen.
* `deferred` - the distance in meters to defer location updates, configured on the settings screen.
* `significant_change` - a string indicating the significant change mode, `disabled`, `enabled` or `exclusive`.
* `locations_in_payload` - the number of locations that were sent in the batch along with this location

### Response

Your server must reply with a JSON response containing:

```json
{
  "result": "ok"
}
```

This indicates to the app that the batch was received, and it will delete those points from the local cache. If the app receives any other response, it will keep the data locally and try to send it again at the next interval.

If you are unable to return this JSON, you can set the "Consider HTTP 2XX Successful" in the Settings app, and then any HTTP 2xx response will be considered successful.


#### Configuration by Server Response

The server can change the settings listed below through its upload response.
The example lists accepted alternatives; choose one value for each property.

```json

{
  "result": "ok",
  "set": {
    "send_interval": "1s|5s|10s|15s|30s|1m|2m|5m|10m|30m|off",
    "trip_mode": "walk|run|bicycle|car|taxi|bus|tram|train|metro|gondola|monorail|sleigh|plane|boat|scooter",
    "main": {
      "tracking_mode": "off|standard|significant|both",
      "visit_tracking": true|false,
      "desired_accuracy": "nav|best|10m|100m|1km|3km",
      "activity_type": "other|car|fitness|nav|air",
      "background_indicator": true|false,
      "pause_automatically": true|false,
      "logging_mode": "all|latest|owntracks",
      "batch_size": 50|100|200|500|1000,
      "resume_with_geofence": "off|100m|200m|500m|1km|2km",
      "min_distance": "off|1m|10m|50m|100m|500m",
      "min_time": "1s|5s|10s|30s|1m|5m",
      "max_accuracy": "off|10m|50m|100m|500m|1000m",
      "stop_radius": "off|10m|20m|50m|100m|200m",
      "stop_time": "1m|2m|5m|10m|20m",
    },
    "trip": {
      "desired_accuracy": "nav|best|10m|100m|1km|3km",
      "activity_type": "other|car|fitness|nav|air",
      "background_indicator": true|false,
      "prevent_screen_lock": true|false,
      "logging_mode": "all|latest|owntracks",
      "batch_size": 50|100|200|500|1000,
      "min_distance": "off|1m|10m|50m|100m|500m",
      "min_time": "1s|5s|10s|30s|1m|5m",
    }
  }
}
```

Most values are strings; batch sizes are numbers and toggles are booleans.
The example's `stop_time` shorthand is outdated: the current implementation
accepts `1min`, `2min`, `5min`, `10min`, or `20min`.

The `main` settings control normal tracking; `trip` settings apply during a trip.

Setting `send_interval=off` disables automatic uploads. The server cannot send
another configuration response until the app makes a request, so the user may
need to re-enable sending or tap Send Now. Setting `tracking_mode=off` disables
standard and significant-change updates; visits remain a separate setting.

Include only the properties you intend to change. Repeating settings in every
response can overwrite choices made in the app.


### Current Location

When the queue contains more records than the batch size and a latest fix is
available, a GeoJSON request also includes `current`. This field describes that
fix even while older records are being uploaded. A backend can use it to display
the current position without waiting for the backlog to clear.


### Current Trip

If a trip is active, an object called `trip` will be included in the request as well, with information about the current trip. This object will contain the following properties:

* `distance` - current trip distance in meters as calculated by the device
* `mode` - the trip mode as a string
* `current_location` - a `location` record that represents the most recent location of the device
* `start_location` - a `location` record that represents the location at the start of the trip
* `start` - an ISO8601 timestamp representing the time the trip was started. this may be slightly different from the timestamp in the start location.


## Home Assistant Integration

Setting the Logging Mode to "Owntracks" will record the data in a format that can be used with Home Assistant.

https://www.home-assistant.io/integrations/owntracks/

OwnTracks sends one queued point per request and retains the remaining points
for later sends.

In the Overland Server URL setup, set the "Device ID" to the Owntracks topic you want, for example "username/device". This will be appended to the string "owntracks/" for the topic URL. Use the "Access Token" field for your Home Assistant username.



## Development Setup

This assumes you have [Xcode](https://developer.apple.com/xcode/) and [Homebrew](https://brew.sh) installed. A paid Apple Developer account is not needed.

* `git clone https://github.com/SoPat712/Overland-iOS.git && cd Overland-iOS`
* `brew install cocoapods`
* `pod install`
* `open Overland.xcworkspace`
* In Project Navigator, select *Overland*, and update Project Settings:
    * Identity → Bundle Identifier: *com.yourname.overland*
    * Signing → Team: *Personal Team*
* Set the same signing team on *OverlandTrackingActivity* and give it a bundle
  identifier beneath the app identifier, such as *com.yourname.overland.TrackingActivity*.
* Plug in your iOS device
* Product → Destination -> select your device
* Product → Run (⌘R)
* On your iOS device: Settings -> General -> Device Management -> Developer App -> Trust
* You can now launch the Overland app on your iOS device


### Simulated route test

```bash
python3 ci_scripts/simulated_route_test.py /path/to/Overland.app
```

This test requires the iOS 27 simulator runtime and IDB. Shut down other
simulators first. The script creates a disposable iPhone simulator, installs
the supplied app, grants location and motion access, and records a fake Portland
route against a localhost receiver. The receiver rejects the first upload to
check that retry preserves its records. It also checks replay-store migration,
record preservation, and ID continuity after the last old point expires.

The test also checks panel resizing, map controls, trip recording, tab switching,
timeline selection, panning, stop confirmation, and exact numeric entry in Settings.
It removes its simulator afterward and writes results to
`/tmp/overland-fake-route-results.json`. It takes no screenshots and uses no
production endpoint. Pre-granted permissions and simulated movement do not test
first-use prompts or real-device background delivery.

To inspect replay without sending test locations to a server, first install and
launch the app on a booted iPhone simulator, then run:

```bash
python3 ci_scripts/load_replay_demo.py <simulator-udid>
```

This replaces only tagged demo records in the local 24-hour history store.
It leaves the upload queue and other history records alone. The 46-mile Portland
to Salem fixture follows a route from the [Project OSRM demo service](https://router.project-osrm.org/)
based on [OpenStreetMap data](https://www.openstreetmap.org/copyright).
Its speeds are routing-profile estimates, not measured speeds or posted limits.

Both `ci_scripts/smoke_test.sh` and `ci_scripts/idb_ui_test.sh` skip screenshots
by default. Set `CAPTURE_SCREENSHOTS=1` only when you want a capture. The smoke
script builds with two concurrent operations and lower scheduling priority.

## Upstream contributions

This fork incorporates work from Aaron Parecki and the upstream contributors:

- [yniverz, PR #180](https://github.com/aaronpk/Overland-iOS/pull/180): precision,
  filtering, stationary stopping, and subsequent pause/settings follow-ups.
- [Rubeanie, PR #190](https://github.com/aaronpk/Overland-iOS/pull/190): custom HTTP
  headers, adapted to this fork's request handling and SwiftUI settings.
- [dietrichmax, PR #193](https://github.com/aaronpk/Overland-iOS/pull/193): Colota link.
- [calebgab, PR #187](https://github.com/aaronpk/Overland-iOS/pull/187): Reitti link.
- [weltspion, PR #195](https://github.com/aaronpk/Overland-iOS/pull/195): Geomanic listing.

These are local integrations, not claims that upstream issues or PRs are closed.
Replay retains only 24 hours; send diagnostics retain only the current session's
last 50 outcomes. Real-device background delivery, battery use, WiFi identity
access, purchases, VoiceOver, iPad layout, and older iOS versions need further
validation.

## License

Contributions from 2017 onward are copyright by Aaron Parecki and contributors

Contributions from 2013-2016 are copyright by Esri, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
