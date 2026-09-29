import CoreLocation

@MainActor
@objc final class OverlandLocationEngine: NSObject {
    @objc static let shared = OverlandLocationEngine()

    private var backgroundSession: CLBackgroundActivitySession?
    private var liveTask: Task<Void, Never>?
    private var runningActivity: UInt?
    private var generation = 0

    @objc func startBackgroundSession() {
        if backgroundSession == nil {
            backgroundSession = CLBackgroundActivitySession()
        }
    }

    @objc func endBackgroundSession() {
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    @objc(runLiveUpdatesWithActivityType:)
    func runLiveUpdates(activityType: UInt) {
        if runningActivity == activityType, let task = liveTask, !task.isCancelled { return }
        stopLiveUpdates()
        runningActivity = activityType
        let current = generation
        let config = liveConfiguration(activityType: activityType)
        liveTask = Task { [weak self] in
            defer {
                // A canceled task must not clear the task that replaced it.
                if self?.generation == current {
                    self?.liveTask = nil
                    self?.runningActivity = nil
                }
            }
            do {
                for try await update in CLLocationUpdate.liveUpdates(config) {
                    guard !Task.isCancelled, self?.generation == current else { break }
                    if let loc = update.location {
                        GLManager.shared().processEngineLocation(loc)
                    }
                    guard !Task.isCancelled, self?.generation == current else { break }
                    if #available(iOS 18.0, *) {
                        GLManager.shared().processEngineStationary(update.stationary)
                    } else {
                        GLManager.shared().processEngineStationary(update.isStationary)
                    }
                }
            } catch {
                if !Task.isCancelled { NSLog("Location updates ended: %@", error.localizedDescription) }
            }
        }
    }

    @objc func stopLiveUpdates() {
        generation += 1
        liveTask?.cancel()
        liveTask = nil
        runningActivity = nil
    }

    private func liveConfiguration(activityType: UInt) -> CLLocationUpdate.LiveConfiguration {
        switch CLActivityType(rawValue: Int(activityType)) ?? .other {
        case .automotiveNavigation: return .automotiveNavigation
        case .fitness: return .fitness
        case .otherNavigation: return .otherNavigation
        case .airborne: return .airborne
        default: return .default
        }
    }
}
