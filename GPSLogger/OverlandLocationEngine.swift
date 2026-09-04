import CoreLocation

// Feeds GLManager's existing queue from the iOS 17 async CoreLocation APIs.
// The CLLocationManager delegate path stays for significant-change visits,
// heading, region and visit events; this engine is the standard-update source.
@objc final class OverlandLocationEngine: NSObject {
    @objc static let shared = OverlandLocationEngine()

    private var backgroundSession: CLBackgroundActivitySession?
    private var liveTask: Task<Void, Never>?
    private var runningConfigKey: String?

    @objc func startBackgroundSession() {
        if backgroundSession == nil {
            backgroundSession = CLBackgroundActivitySession()
        }
    }

    @objc func endBackgroundSession() {
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    @objc(runLiveUpdatesWithActivityType:desiredAccuracy:)
    func runLiveUpdates(activityType: UInt, desiredAccuracy: CLLocationAccuracy) {
        // Skip if a loop is already running with the same configuration, e.g.
        // the periodic restart nudges from the significant-change path
        let key = "\(activityType)-\(desiredAccuracy)"
        if key == runningConfigKey, let task = liveTask, !task.isCancelled {
            return
        }
        liveTask?.cancel()
        runningConfigKey = key
        let config = liveConfiguration(activityType: activityType, desiredAccuracy: desiredAccuracy)
        liveTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(config) {
                    if Task.isCancelled { break }
                    if let loc = update.location {
                        await MainActor.run {
                            GLManager.shared().processEngineLocation(loc)
                        }
                    }
                }
            } catch {
                // liveUpdates ended; a new loop is started on the next enable/restart
            }
        }
    }

    @objc func stopLiveUpdates() {
        liveTask?.cancel()
        liveTask = nil
        runningConfigKey = nil
    }

    private func liveConfiguration(activityType: UInt, desiredAccuracy: CLLocationAccuracy) -> CLLocationUpdate.LiveConfiguration {
        switch CLActivityType(rawValue: Int(activityType)) ?? .other {
        case .automotiveNavigation:
            return .automotiveNavigation
        case .fitness:
            return .fitness
        case .otherNavigation:
            return .otherNavigation
        case .airborne:
            return .airborne
        default:
            return .default
        }
    }
}
