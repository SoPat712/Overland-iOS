import SwiftUI
import UIKit

// Thin observable wrapper over GLManager. Views read live status here and
// write settings through GLManager so its side effects (enableTracking etc.)
// still run. ObjC can't be observed directly, so notifications bump a tick.
@Observable
final class GLManagerBridge {
    static let shared = GLManagerBridge()

    private(set) var tick = 0
    private(set) var trackingEnabled = false
    private(set) var queueCount = 0
    private(set) var lastLocationAge = "0:00"
    private(set) var lastLocationText = "0.0000\n0.0000"
    private(set) var lastAccuracyText = "+/-0m 0m"
    private(set) var speed = 0
    private(set) var tripInProgress = false
    private(set) var sending = false
    private(set) var endpointSet = false
    private(set) var speedUnit = "MPH"

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
        endpointSet = gl.apiEndpointURL() != nil
        speedUnit = Locale.current.usesMetricSystem ? "KM/H" : "MPH"

        if let loc = gl.lastLocation {
            lastLocationText = String(format: "%.4f\n%.4f", loc.coordinate.latitude, loc.coordinate.longitude)
            lastAccuracyText = String(format: "+/-%.0fm %.0fm", loc.horizontalAccuracy, loc.verticalAccuracy)
            var age = Int(-loc.timestamp.timeIntervalSinceNow)
            if age == 1 { age = 0 }
            lastLocationAge = Self.timeFormatted(age)
            let metric = Locale.current.usesMetricSystem
            let raw = metric ? loc.speed * 3.6 : loc.speed * 2.23694
            speed = max(0, Int(raw.rounded()))
        } else {
            lastLocationAge = "0:00"
            lastLocationText = "0.0000\n0.0000"
            lastAccuracyText = "+/-0m 0m"
            speed = 0
        }
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

    var trackingOn: Bool {
        get { trackingEnabled }
        set {
            newValue ? GLManager.shared().startAllUpdates() : GLManager.shared().stopAllUpdates()
            refresh()
        }
    }

    var trackingModeIndex: Int {
        get { Int(GLManager.shared().trackingMode.rawValue) }
        set {
            GLManager.shared().trackingMode = GLTrackingMode(rawValue: UInt32(newValue)) ?? kGLTrackingModeOff
            refresh()
        }
    }

    var visitTracking: Bool {
        get { GLManager.shared().visitTrackingEnabled }
        set {
            GLManager.shared().visitTrackingEnabled = newValue
            refresh()
        }
    }

    var accuracyIndex: Int {
        get {
            switch GLManager.shared().desiredAccuracy {
            case kCLLocationAccuracyBestForNavigation: return 0
            case kCLLocationAccuracyBest: return 1
            case 10: return 2
            case 100: return 3
            case 1000: return 4
            default: return 5
            }
        }
        set {
            let values: [CLLocationAccuracy] = [kCLLocationAccuracyBestForNavigation, kCLLocationAccuracyBest, 10, 100, 1000, 3000]
            GLManager.shared().desiredAccuracy = values[newValue]
            refresh()
        }
    }

    var activityIndex: Int {
        get {
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
        get { GLManager.shared().showBackgroundLocationIndicator }
        set {
            GLManager.shared().showBackgroundLocationIndicator = newValue
            refresh()
        }
    }

    var pausesAutomatically: Bool {
        get { GLManager.shared().pausesAutomatically }
        set {
            GLManager.shared().pausesAutomatically = newValue
            refresh()
        }
    }

    var loggingModeIndex: Int {
        get { Int(GLManager.shared().loggingMode.rawValue) }
        set {
            GLManager.shared().loggingMode = GLLoggingMode(rawValue: UInt32(newValue)) ?? kGLLoggingModeAllData
            refresh()
        }
    }

    var batchIndex: Int {
        get {
            switch GLManager.shared().pointsPerBatch {
            case 50: return 0
            case 100: return 1
            case 500: return 3
            case 1000: return 4
            default: return 2
            }
        }
        set {
            GLManager.shared().pointsPerBatch = [50, 100, 200, 500, 1000][newValue]
            refresh()
        }
    }

    var discardDistanceIndex: Int {
        get { distanceIndex(GLManager.shared().discardPointsWithinDistance) }
        set {
            GLManager.shared().discardPointsWithinDistance = [-1, 1, 10, 50, 100, 500][newValue]
            refresh()
        }
    }

    private func distanceIndex(_ v: CLLocationDistance) -> Int {
        if v == -1 { return 0 }
        if v < 10 { return 1 }
        if v < 50 { return 2 }
        if v < 100 { return 3 }
        if v < 500 { return 4 }
        return 5
    }

    var discardSecondsIndex: Int {
        get {
            let s = GLManager.shared().discardPointsWithinSeconds
            if s < 5 { return 0 }
            if s < 10 { return 1 }
            if s < 30 { return 2 }
            if s < 60 { return 3 }
            if s < 120 { return 4 }
            return 5
        }
        set {
            GLManager.shared().discardPointsWithinSeconds = [1, 5, 10, 30, 60, 120][newValue]
            refresh()
        }
    }

    var discardAccuracyIndex: Int {
        get {
            let v = GLManager.shared().discardPointsOutsideAccuracy
            if v == -1 { return 0 }
            if v < 50 { return 1 }
            if v < 100 { return 2 }
            if v < 500 { return 3 }
            if v < 1000 { return 4 }
            return 5
        }
        set {
            GLManager.shared().discardPointsOutsideAccuracy = [-1, 10, 50, 100, 500, 1000][newValue]
            refresh()
        }
    }

    var stopRadiusIndex: Int {
        get {
            let v = GLManager.shared().stopsAutomaticallyRadius
            if v == -1 { return 0 }
            if v < 20 { return 1 }
            if v < 50 { return 2 }
            if v < 100 { return 3 }
            if v < 200 { return 4 }
            return 5
        }
        set {
            GLManager.shared().stopsAutomaticallyRadius = [-1, 10, 20, 50, 100, 200][newValue]
            refresh()
        }
    }

    var stopAfterIndex: Int {
        get {
            let m = GLManager.shared().stopsAutomaticallyAfterSeconds
            if m < 120 { return 0 }
            if m < 300 { return 1 }
            if m < 600 { return 2 }
            if m < 1200 { return 3 }
            return 4
        }
        set {
            GLManager.shared().stopsAutomaticallyAfterSeconds = [60, 120, 300, 600, 1200][newValue]
            refresh()
        }
    }

    var notifications: Bool {
        get { GLManager.shared().notificationsEnabled }
        set {
            GLManager.shared().notificationsEnabled = newValue
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
            self.buttonStyle(.borderedProminent).tint(tint)
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
