import SwiftUI

struct SettingsHelpButton: View {
    let topic: SettingsHelpTopic
    @State private var showingHelp = false

    var body: some View {
        Button {
            showingHelp = true
        } label: {
            Image(systemName: "info.circle")
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About \(topic.rawValue)")
        .sheet(isPresented: $showingHelp) {
            SettingsHelpView(topic: topic)
        }
    }
}

struct SettingsSectionHeader: View {
    let title: String
    let topic: SettingsHelpTopic

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            SettingsHelpButton(topic: topic)
        }
        .textCase(nil)
    }
}

struct SettingsHelpView: View {
    let topic: SettingsHelpTopic
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(topic.entries, id: \.title) { entry in
                    Section {
                        Text(entry.detail)
                        Link(entry.source.title, destination: entry.source.url)
                            .font(.footnote)
                    } header: {
                        Text(entry.title)
                    }
                }
            }
            .navigationTitle(topic.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SettingExplanation {
    let title: String
    let detail: String
    let source: SettingsSource

    init(_ title: String, _ detail: String, _ source: SettingsSource) {
        self.title = title
        self.detail = detail
        self.source = source
    }
}

private enum SettingsSource {
    case accuracy, activity, significant, background, coreLocation, readme, implementation

    var title: String {
        switch self {
        case .accuracy: return "Apple: Desired accuracy"
        case .activity: return "Apple: Activity type"
        case .significant: return "Apple: Significant-change monitoring"
        case .background: return "Apple engineer: Background updates (iOS 16.4+)"
        case .coreLocation: return "Apple: Core Location"
        case .readme: return "Overland README: Usage profiles"
        case .implementation: return "Overland README (published version)"
        }
    }

    var url: URL {
        let path: String
        switch self {
        case .accuracy: path = "https://developer.apple.com/documentation/corelocation/cllocationmanager/desiredaccuracy"
        case .activity: path = "https://developer.apple.com/documentation/corelocation/cllocationmanager/activitytype"
        case .significant: path = "https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges()"
        case .background: path = "https://developer.apple.com/forums/thread/726945"
        case .coreLocation: path = "https://developer.apple.com/documentation/corelocation"
        case .readme: path = "https://github.com/SoPat712/Overland-iOS#usage-profiles"
        case .implementation: path = "https://github.com/SoPat712/Overland-iOS#api"
        }
        return URL(string: path)!
    }
}

enum SettingsHelpTopic: String {
    case presets = "Usage Presets"
    case permissions = "Permissions"
    case tracking = "Tracking"
    case precision = "Precision"
    case stationary = "Stationary Behavior"
    case batching = "Logging and Sending"
    case background = "Background Indicator"
    case automation = "WiFi and Notifications"
    case server = "Server Configuration"
    case trip = "Trip Settings"

    fileprivate var entries: [SettingExplanation] {
        switch self {
        case .presets:
            return [
                .init("What changes", "Presets change normal tracking mode, accuracy, activity, pausing, resume distance, stationary thresholds, point filters, the background indicator and visit tracking. They leave the server, credentials, logging format, send interval, batch size and trip-specific settings alone. The resume distance is shared with trips and does change. They do not start a stopped tracker. Finish an active trip before applying one. Editing a covered setting changes the selector to Custom.", .implementation),
                .init("High Resolution", "For detailed route recording. Standard updates, Best accuracy, Other activity, automatic pausing and geofence resume off. Point filters and stationary stopping are off; the indicator is on and visits are off. Based on the README's high-resolution profile. More detail costs power; one point per second is not guaranteed.", .readme),
                .init("Low Power", "For coarse location history. Significant-change updates, Other activity, automatic pausing on and a 500 m resume distance. The stored standard-update accuracy is 100 m, but it does not control significant-change accuracy. Pausing and resume values also concern standard updates, not the timing of significant changes. Point filters, stationary stopping, the indicator and visits are off. Based on the README's low-resolution profile; this cannot capture a detailed route.", .readme),
                .init("Balanced", "For everyday history with more detail while moving. Both update sources, 100 m requested accuracy, Other activity, and stationary stopping within 50 m after 3 minutes. Automatic pausing and geofence resume are off; significant changes resume tracking. Point filters are off, the indicator is on and visits are off. Overland's concrete starting values for the README's battery-saving/high-resolution approach; battery savings are not measured or guaranteed.", .readme),
                .init("Walking / Running", "High Resolution with Fitness activity, to describe the expected movement to iOS. All other High Resolution values apply. This is an Overland recommendation based on Apple's activity guidance, not an Apple-provided preset.", .activity),
                .init("Driving", "High Resolution with Automotive activity and Navigation accuracy. All other High Resolution values apply. This is an Overland recommendation for detailed driving tracks, not an Apple-provided preset. Navigation accuracy can use more power.", .activity)
            ]
        case .permissions:
            return [
                .init("Location access", "iOS controls whether Overland may obtain location. When in Use permits foreground use and some active background sessions; Always supports background location use more broadly. Denied or restricted access must be addressed in iOS Settings. Permission alone does not start tracking.", .coreLocation),
                .init("Precise Location", "If Precise Location is disabled in iOS Settings, requesting a smaller accuracy value cannot restore precise fixes.", .accuracy)
            ]
        case .tracking:
            return [
                .init("Tracking Enabled", "Starts or stops collection. Stopping keeps queued records for later sending. Trips temporarily use their own tracking configuration and restore the earlier tracking state when ended.", .implementation),
                .init("Update Mode", "Off disables standard and significant-change updates; visit tracking is separate. Standard requests regular location updates. Significant uses iOS's coarse movement service. Both enables both sources and permits Overland's stationary radius/time logic to pause standard updates until significant movement.", .implementation),
                .init("Significant changes", "iOS schedules these events, not the send interval or distance filter. Apple describes movements of around 500 m or more and says not to expect updates more often than every five minutes. Network availability affects timeliness. This is unsuitable for a detailed walking route.", .significant),
                .init("Visit Tracking", "Records iOS-detected arrivals and departures at places. Visit events are separate from continuous route points and may arrive after the visit occurred.", .coreLocation)
            ]
        case .precision:
            return [
                .init("Accuracy Preset / Desired Accuracy", "Custom requests an accuracy in meters; a smaller value asks for a more precise fix. Best requests the best available accuracy; Navigation requests navigation-grade accuracy. These are requests, not guarantees: less accurate fixes may arrive first, and higher precision can take more time and power. Desired accuracy affects standard updates, not significant-change monitoring.", .accuracy),
                .init("Activity Type", "Tells iOS the expected activity: Other, Automotive, Fitness, other Navigation, or Airborne. It is a hint used when deciding whether updates can pause, not a motion classifier or trip label. Choose the activity you actually expect to perform.", .activity),
                .init("Min Distance Between Points", "Discards received points closer than this many meters to the last accepted fix. Off keeps them. This filters recorded data after delivery; it does not directly reduce GPS sampling or guarantee lower battery use.", .implementation),
                .init("Min Time Between Points", "Discards received points less than this many seconds after the last accepted fix. Off disables this filter. It is not a request to iOS for a fixed sampling interval.", .implementation),
                .init("Max Accuracy of Points", "Rejects fixes whose reported horizontal uncertainty exceeds this many meters. Lower values are stricter and may leave gaps indoors or during a weak fix. Off accepts any otherwise-valid accuracy. This is different from the accuracy requested from iOS.", .implementation)
            ]
        case .stationary:
            return [
                .init("Stop Within Radius / Stop After", "In Both mode, Overland pauses standard updates after the accepted fixes remain within the radius for the configured time. Significant-change monitoring continues and can resume them after movement. Radius Off disables this behavior. This is separate from iOS automatic pausing and does not stop an active trip.", .implementation),
                .init("Pause Updates Automatically", "Allows iOS to decide when standard updates can pause. Turning it off favors continuity and may use more power. Overland handles pause callbacks and can install a resume region; during a trip, automatic pausing can end the trip.", .implementation),
                .init("Resume After Moving", "After an automatic pause, Overland creates a circular region around the last fix. Exiting it can resume an enabled tracker. This distance is shared by normal and trip settings. Region delivery is not an exact crossing alarm. Off disables the resume region; disabling automatic pausing also clears this value.", .implementation)
            ]
        case .batching:
            return [
                .init("Logging Mode", "All Data queues GeoJSON records. Only Latest deliberately replaces queued location data with the latest update. OwnTracks uses OwnTracks JSON and sends one location per request; unsent fixes stay queued. Select the format your server accepts.", .implementation),
                .init("Locations per Batch", "Limits the number of queued records in a GeoJSON request. Smaller batches make smaller requests; larger ones can drain a backlog with fewer requests. OwnTracks sends one point at a time regardless of this setting.", .implementation),
                .init("Send Interval / Send Every", "Automatic sends are considered when locations arrive after this interval. This is not an exact background timer. Off means manual sending. Failed attempts retain their points; Last Sent changes only after the server acknowledges success.", .implementation)
            ]
        case .background:
            return [
                .init("Show Background Indicator", "Requests the system's visible location-use indicator during background tracking. It is not a permission switch, and turning it off does not stop collection. The actual appearance is controlled by iOS.", .coreLocation),
                .init("Background continuity", "In the linked iOS 16.4 discussion, an Apple engineer describes suspension with combined standard/significant updates at low accuracy and with distance filtering. The guidance uses continuous background permission, no manager distance filter, and requested accuracy below 1,000 m, or enables the indicator. This is guidance for that configuration, not a guarantee for every device or OS release. Overland's saved-point filters are separate from the manager's distance filter.", .background)
            ]
        case .automation:
            return [
                .init("WiFi Zones", "Associates a network name with fixed coordinates to use at that location. BSSID can distinguish access points sharing a name. iOS must expose the network information; missing permission or entitlement can prevent a match. Use the actual location of the network, not a general city center.", .implementation),
                .init("Notifications", "Controls Overland's local tracking and send-related notifications. iOS notification permission is also required. This does not turn location tracking or background execution on.", .implementation)
            ]
        case .server:
            return [
                .init("Endpoint and token", "The endpoint is your receiving server's HTTP(S) URL. Normal GeoJSON requests use Bearer authentication when a token is provided. OwnTracks uses Basic authentication with the Base64-encoded username:password you enter. Save applies the draft; Clear Server URL disconnects the endpoint without deleting queued points.", .implementation),
                .init("Device ID / Include unique_id", "Device ID labels records; it is not the login username. Include unique_id adds the device's vendor identifier to supported location payloads. Leave it off if your server does not need it.", .implementation),
                .init("Custom HTTP Headers", "Adds headers required by your server or reverse proxy. Names must be unique and values cannot contain line breaks. Authorization and transport-controlled headers are reserved. Header values can contain credentials, so treat them like your access token.", .implementation),
                .init("Accept Any Successful HTTP Response", "When enabled, any successful 2xx response acknowledges a batch, including an empty body. Otherwise Overland requires a JSON object with result set to ok. Match your server's contract: acknowledgment removes the sent records from the queue.", .implementation),
                .init("Status and Recent Sends", "Configured means a URL is saved, not that a connection has been verified. The chart shows up to 50 outcomes from this app process: green success, orange server rejection, red network failure. It resets after relaunch.", .implementation)
            ]
        case .trip:
            return [
                .init("Trip overrides", "Accuracy, activity, logging mode, batch size, point filters, the indicator and pausing override normal settings only during a trip. Their meanings match the normal controls. The resume-region distance is shared. Automatic pausing can end a trip; leave it off if you want to end trips manually.", .implementation),
                .init("Prevent Screen Lock", "Keeps the display awake during an active trip. The display can consume substantial power. Ending the trip releases the override.", .implementation),
                .init("Trip mode and timeline", "The selected mode labels the trip; it is separate from iOS Activity Type. The timeline shows up to 1,000 recent trip points. Scrubbing selects an older point; Live follows the latest point again.", .implementation)
            ]
        }
    }
}
