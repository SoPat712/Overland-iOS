import SwiftUI
import UIKit

// One entry per HTTP send attempt, oldest first.
struct SendStatusEntry: Identifiable, Equatable {
    enum Kind: Int { case success = 0, server = 1, network = 2 }
    let id: Int
    let date: Date
    let kind: Kind
}

// Thin observable wrapper over GLManager. Views read live status here and
// write settings through GLManager so its side effects (enableTracking etc.)
// still run. ObjC can't be observed directly, so notifications bump a tick.
@Observable
final class GLManagerBridge {
    static let shared = GLManagerBridge()

    private(set) var tick = 0
    private(set) var trackingEnabled = false
    private(set) var queueCount = 0
    private(set) var lastLocationAge = "–"
    private(set) var lastLocationText = "–"
    private(set) var lastAccuracyText = "No location yet"
    private(set) var speed = 0
    private(set) var tripInProgress = false
    private(set) var sending = false
    private(set) var endpointSet = false
    private(set) var speedUnit = "MPH"
    private(set) var lastSentText = "–"
    private(set) var sendHistory: [SendStatusEntry] = []

    private var timer: Timer?

    private init() {
        let nc = NotificationCenter.default
        for name in [GLNewDataNotification, GLSendingStartedNotification, GLSendingFinishedNotification,
                     GLSettingsChangedNotification, GLAuthorizationStatusChangedNotification, GLNewActivityNotification] {
            nc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func refresh() {
        guard let gl = GLManager.shared() else { return }
        tick += 1
        trackingEnabled = gl.trackingEnabled
        queueCount = Int(gl.currentPointsInQueue)
        tripInProgress = gl.tripInProgress()
        sending = gl.sendInProgress
        endpointSet = !(gl.apiEndpointURL() ?? "").isEmpty
        speedUnit = (Locale.current.measurementSystem == .metric) ? "KM/H" : "MPH"

        if let sent = gl.lastSentDate {
            lastSentText = Self.timeFormatted(max(0, Int(-sent.timeIntervalSinceNow))) + " ago"
        } else {
            lastSentText = "–"
        }

        let results = (gl.recentSendResults() as? [[String: NSNumber]]) ?? []
        sendHistory = results.enumerated().map { idx, entry in
            SendStatusEntry(
                id: idx,
                date: Date(timeIntervalSince1970: entry["ts"]?.doubleValue ?? 0),
                kind: SendStatusEntry.Kind(rawValue: entry["status"]?.intValue ?? SendStatusEntry.Kind.network.rawValue) ?? .network
            )
        }

        if let loc = gl.lastLocation {
            lastLocationText = String(format: "%.4f\n%.4f", loc.coordinate.latitude, loc.coordinate.longitude)
            lastAccuracyText = String(format: "±%.0f m", loc.horizontalAccuracy)
            let age = max(0, Int(-loc.timestamp.timeIntervalSinceNow))
            lastLocationAge = Self.timeFormatted(age)
            let metric = (Locale.current.measurementSystem == .metric)
            let raw = metric ? loc.speed * 3.6 : loc.speed * 2.23694
            speed = max(0, Int(raw.rounded()))
        } else {
            lastLocationAge = "–"
            lastLocationText = "–"
            lastAccuracyText = "No location yet"
            speed = 0
        }
    }

    func saveServer(url: String, token: String, deviceId: String, uniqueId: Bool, acceptHTTP: Bool, headers: [String: String]) {
        guard let gl = GLManager.shared() else { return }
        gl.saveNewDeviceId(deviceId)
        gl.customHTTPHeaders = headers
        UserDefaults.standard.set(uniqueId, forKey: GLIncludeUniqueIdDefaultsName)
        UserDefaults.standard.set(acceptHTTP, forKey: GLConsiderHTTP200SuccessDefaultsName)
        gl.saveNewAPIEndpoint(url, andAccessToken: token)
        refresh()
    }

    func clearServer() {
        GLManager.shared().saveNewAPIEndpoint(nil, andAccessToken: nil)
        refresh()
    }

    private static func timeFormatted(_ totalSeconds: Int) -> String {
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // Write-through bindings: settings changes go through GLManager so its
    // side effects (enableTracking, persistence) run, then views refresh.

    var usageProfile: Int {
        get {
            _ = tick
            return GLManager.shared().usageProfile()
        }
        set {
            GLManager.shared().applyUsageProfile(newValue)
            refresh()
        }
    }

    var trackingOn: Bool {
        get {
            _ = tick
            return trackingEnabled
        }
        set {
            newValue ? GLManager.shared().startAllUpdates() : GLManager.shared().stopAllUpdates()
            refresh()
        }
    }

    var trackingModeIndex: Int {
        get {
            _ = tick
            return Int(GLManager.shared().trackingMode.rawValue)
        }
        set {
            GLManager.shared().trackingMode = GLTrackingMode(rawValue: UInt32(newValue))
            refresh()
        }
    }

    var visitTracking: Bool {
        get {
            _ = tick
            return GLManager.shared().visitTrackingEnabled
        }
        set {
            GLManager.shared().visitTrackingEnabled = newValue
            refresh()
        }
    }

    // Accuracy: Custom (meters via slider), Best, or Navigation-grade.
    var accuracyPreset: Int {
        get {
            _ = tick
            switch GLManager.shared().desiredAccuracy {
            case kCLLocationAccuracyBestForNavigation: return 2
            case kCLLocationAccuracyBest: return 1
            default: return 0
            }
        }
        set {
            switch newValue {
            case 2: GLManager.shared().desiredAccuracy = kCLLocationAccuracyBestForNavigation
            case 1: GLManager.shared().desiredAccuracy = kCLLocationAccuracyBest
            default: GLManager.shared().desiredAccuracy = accuracyMeters
            }
            refresh()
        }
    }

    var accuracyMeters: Double {
        get {
            _ = tick
            let v = GLManager.shared().desiredAccuracy
            return v > 0 ? v : 100
        }
        set {
            GLManager.shared().desiredAccuracy = newValue.rounded()
            refresh()
        }
    }

    var activityIndex: Int {
        get {
            _ = tick
            switch GLManager.shared().activityType {
            case .automotiveNavigation: return 1
            case .fitness: return 2
            case .otherNavigation: return 3
            case .airborne: return 4
            default: return 0
            }
        }
        set {
            let values: [CLActivityType] = [.other, .automotiveNavigation, .fitness, .otherNavigation, .airborne]
            GLManager.shared().activityType = values[newValue]
            refresh()
        }
    }

    var backgroundIndicator: Bool {
        get {
            _ = tick
            return GLManager.shared().showBackgroundLocationIndicator
        }
        set {
            GLManager.shared().showBackgroundLocationIndicator = newValue
            refresh()
        }
    }

    var locationPermission: String {
        _ = tick
        return GLManager.shared().authorizationStatusAsString()
    }

    func requestLocationPermission() {
        GLManager.shared().requestAuthorizationPermission()
        refresh()
    }

    var resumeDistanceMeters: Double {
        get {
            _ = tick
            return max(0, GLManager.shared().resumesAfterDistance)
        }
        set {
            GLManager.shared().resumesAfterDistance = newValue < 1 ? -1 : newValue
            refresh()
        }
    }

    var pausesAutomatically: Bool {
        get {
            _ = tick
            return GLManager.shared().pausesAutomatically
        }
        set {
            GLManager.shared().pausesAutomatically = newValue
            if !newValue {
                GLManager.shared().resumesAfterDistance = -1
            }
            refresh()
        }
    }

    var loggingModeIndex: Int {
        get {
            _ = tick
            return Int(GLManager.shared().loggingMode.rawValue)
        }
        set {
            GLManager.shared().loggingMode = GLLoggingMode(rawValue: UInt32(newValue))
            refresh()
        }
    }

    var batchValue: Double {
        get {
            _ = tick
            return Double(GLManager.shared().pointsPerBatch)
        }
        set {
            GLManager.shared().pointsPerBatch = Int32(newValue.rounded())
            refresh()
        }
    }

    // Discard filters. Values <= 0 are stored as -1 ("Off").
    var discardDistanceMeters: Double {
        get {
            _ = tick
            let v = GLManager.shared().discardPointsWithinDistance
            return v > 0 ? v : 0
        }
        set {
            GLManager.shared().discardPointsWithinDistance = newValue < 1 ? -1 : newValue.rounded()
            refresh()
        }
    }

    var discardSecondsValue: Double {
        get {
            _ = tick
            return Double(max(GLManager.shared().discardPointsWithinSeconds, 0))
        }
        set {
            GLManager.shared().discardPointsWithinSeconds = Int32(newValue.rounded())
            refresh()
        }
    }

    var discardAccuracyMeters: Double {
        get {
            _ = tick
            let v = GLManager.shared().discardPointsOutsideAccuracy
            return v > 0 ? v : 0
        }
        set {
            GLManager.shared().discardPointsOutsideAccuracy = newValue < 1 ? -1 : newValue.rounded()
            refresh()
        }
    }

    var stopRadiusMeters: Double {
        get {
            _ = tick
            let v = GLManager.shared().stopsAutomaticallyRadius
            return v > 0 ? v : 0
        }
        set {
            GLManager.shared().stopsAutomaticallyRadius = newValue < 1 ? -1 : newValue.rounded()
            refresh()
        }
    }

    var stopAfterValue: Double {
        get {
            _ = tick
            return Double(GLManager.shared().stopsAutomaticallyAfterSeconds)
        }
        set {
            GLManager.shared().stopsAutomaticallyAfterSeconds = Int32(newValue.rounded())
            refresh()
        }
    }

    var sendIntervalValue: Double {
        get {
            _ = tick
            return max(0, GLManager.shared().sendingInterval.doubleValue)
        }
        set {
            GLManager.shared().sendingInterval = NSNumber(value: newValue < 1 ? -1 : Int(newValue.rounded()))
            refresh()
        }
    }

    var notifications: Bool {
        get {
            _ = tick
            return GLManager.shared().notificationsEnabled
        }
        set {
            GLManager.shared().notificationsEnabled = newValue
            refresh()
        }
    }

    // MARK: Trip Settings (applied only while a trip is in progress)

    var tripAccuracyPreset: Int {
        get {
            _ = tick
            switch GLManager.shared().desiredAccuracyDuringTrip {
            case kCLLocationAccuracyBestForNavigation: return 2
            case kCLLocationAccuracyBest: return 1
            default: return 0
            }
        }
        set {
            switch newValue {
            case 2: GLManager.shared().desiredAccuracyDuringTrip = kCLLocationAccuracyBestForNavigation
            case 1: GLManager.shared().desiredAccuracyDuringTrip = kCLLocationAccuracyBest
            default: GLManager.shared().desiredAccuracyDuringTrip = tripAccuracyMeters
            }
            refresh()
        }
    }

    var tripAccuracyMeters: Double {
        get {
            _ = tick
            let v = GLManager.shared().desiredAccuracyDuringTrip
            return v > 0 ? v : 100
        }
        set {
            GLManager.shared().desiredAccuracyDuringTrip = newValue.rounded()
            refresh()
        }
    }

    var tripMode: String {
        get {
            _ = tick
            return GLManager.shared().currentTripMode ?? "walk"
        }
        set {
            GLManager.shared().currentTripMode = newValue
            refresh()
        }
    }

    var tripDistance: Double {
        _ = tick
        return max(0, GLManager.shared().currentTripDistance())
    }

    var tripDuration: Double {
        _ = tick
        return max(0, GLManager.shared().currentTripDuration())
    }

    var tripBatchValue: Double {
        get {
            _ = tick
            return Double(GLManager.shared().pointsPerBatchDuringTrip)
        }
        set {
            GLManager.shared().pointsPerBatchDuringTrip = Int32(newValue.rounded())
            refresh()
        }
    }

    var tripDiscardDistanceMeters: Double {
        get {
            _ = tick
            let v = GLManager.shared().discardPointsWithinDistanceDuringTrip
            return v > 0 ? v : 0
        }
        set {
            GLManager.shared().discardPointsWithinDistanceDuringTrip = newValue < 1 ? -1 : newValue.rounded()
            refresh()
        }
    }

    var tripDiscardSecondsValue: Double {
        get {
            _ = tick
            return Double(max(GLManager.shared().discardPointsWithinSecondsDuringTrip, 0))
        }
        set {
            GLManager.shared().discardPointsWithinSecondsDuringTrip = Int32(newValue.rounded())
            refresh()
        }
    }

    var tripActivityIndex: Int {
        get {
            _ = tick
            return Int(GLManager.shared().activityTypeDuringTrip.rawValue) - 1
        }
        set {
            GLManager.shared().activityTypeDuringTrip = CLActivityType(rawValue: newValue + 1) ?? .other
            refresh()
        }
    }

    var tripLoggingModeIndex: Int {
        get {
            _ = tick
            return Int(GLManager.shared().loggingModeDuringTrip.rawValue)
        }
        set {
            GLManager.shared().loggingModeDuringTrip = GLLoggingMode(rawValue: UInt32(newValue))
            refresh()
        }
    }

    var tripBackgroundIndicator: Bool {
        get {
            _ = tick
            return GLManager.shared().showBackgroundLocationIndicatorDuringTrip
        }
        set {
            GLManager.shared().showBackgroundLocationIndicatorDuringTrip = newValue
            refresh()
        }
    }

    var tripPausesAutomatically: Bool {
        get {
            _ = tick
            return GLManager.shared().pausesAutomaticallyDuringTrip
        }
        set {
            GLManager.shared().pausesAutomaticallyDuringTrip = newValue
            if !newValue {
                GLManager.shared().resumesAfterDistance = -1
            }
            refresh()
        }
    }

    var screenLock: Bool {
        get {
            _ = tick
            return UserDefaults.standard.bool(forKey: GLScreenLockEnabledDefaultsName)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: GLScreenLockEnabledDefaultsName)
            UIApplication.shared.isIdleTimerDisabled = newValue && tripInProgress
            refresh()
        }
    }
}

extension View {
    // Applies the iOS 26 glass button styles when available, bordered otherwise.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent).tint(tint)
            } else {
                self.buttonStyle(.glass).tint(tint)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent).tint(tint)
            } else {
                self.buttonStyle(.bordered).tint(tint)
            }
        }
    }

    // Liquid Glass background card on iOS 26+, ultra-thin material below.
    @ViewBuilder
    func glassCard() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive())
        } else {
            self.background(.ultraThinMaterial)
        }
    }
}

extension View {
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension View {
    func confirmStopTracking(_ presented: Binding<Bool>, action: @escaping () -> Void) -> some View {
        alert("Stop location tracking?", isPresented: presented) {
            Button("Stop Tracking", role: .destructive, action: action)
            Button("Keep Tracking", role: .cancel) { }
        } message: {
            Text("New locations will stop recording. Queued locations stay saved for sending later.")
        }
    }
}
