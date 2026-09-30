import ActivityKit
import CoreLocation
import Observation
import UIKit
import UserNotifications

@Observable
@MainActor
@objc final class OverlandBackgroundRuntime: NSObject {
    @objc static let shared = OverlandBackgroundRuntime()

    private enum Key {
        static let liveActivity = "OverlandLiveActivityEnabled"
        static let appearance = "OverlandLiveActivityAppearance"
        static let silentAudio = "OverlandSilentAudioEnabled"
    }

    private(set) var activityStatus = "Waiting for tracking"
    private let audio = SilentAudioSession()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var activity: Activity<TrackingActivityAttributes>?
    @ObservationIgnored private var activityObserver: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var reminderRevision = 0
    @ObservationIgnored private var reminderDeadline: Date?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var suppressed = false
    @ObservationIgnored private var wasEligible = false
    @ObservationIgnored private var lastUpdate = Date.distantPast
    @ObservationIgnored private var lastContent: TrackingActivityAttributes.ContentState?

    private override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Key.liveActivity: true,
                                                 Key.appearance: "minimal", Key.silentAudio: false])
    }

    var liveActivityEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.liveActivity) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.liveActivity)
            suppressed = false
            refresh()
        }
    }

    var appearance: String {
        get { UserDefaults.standard.string(forKey: Key.appearance) ?? "minimal" }
        set {
            guard TrackingActivityAttributes.Appearance(rawValue: newValue) != nil else { return }
            UserDefaults.standard.set(newValue, forKey: Key.appearance)
            refresh()
        }
    }

    var silentAudioEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.silentAudio) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.silentAudio)
            refresh()
        }
    }

    var audioStatus: String { audio.status }

    @objc func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        for name in [GLTrackingStateChangedNotification, GLSettingsChangedNotification,
                     GLAuthorizationStatusChangedNotification, GLSendingFinishedNotification] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.suppressed = false
                self.refresh()
                self.audio.refresh()
                self.reloadReminder()
            }
        })
        observers.append(center.addObserver(forName: Notification.Name(GLReminderChangedNotification),
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadReminder() }
        })
        reloadReminder()
        refresh()
    }

    private func reloadReminder() {
        reminderRevision += 1
        let current = reminderRevision
        Task { [weak self] in
            let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
            guard let self, current == self.reminderRevision else { return }
            // Use the existing reminder's deadline, including its cancellation and suppression rules.
            self.reminderDeadline = (requests.first { $0.identifier == "reminder" }?.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            self.refresh()
        }
    }

    func retry() {
        suppressed = false
        refresh()
        audio.retry()
        reloadReminder()
    }

    private var eligible: Bool {
        guard let gl = GLManager.shared(), gl.trackingEnabled else { return false }
        let authorization = gl.locationManager.authorizationStatus
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else { return false }
        return gl.tripInProgress() || gl.trackingMode.rawValue != 0 || gl.visitTrackingEnabled
    }

    private func refresh() {
        let allowed = eligible
        if allowed && !wasEligible { suppressed = false }
        wasEligible = allowed
        audio.setEnabled(allowed && silentAudioEnabled)
        revision += 1
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let current = revision
                await updateActivity()
                if current == revision { break }
            }
            updateTask = nil
        }
    }

    private func updateActivity() async {
        guard eligible && liveActivityEnabled else {
            await endActivities()
            activityStatus = liveActivityEnabled ? "Waiting for tracking and location access" : "Off"
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endActivities()
            activityStatus = "Live Activities are disabled in iOS Settings"
            return
        }
        if activity == nil {
            if let existing = Activity<TrackingActivityAttributes>.activities.first(where: {
                $0.activityState == .active || $0.activityState == .stale
            }) {
                observe(existing)
            }
        }
        let gl = GLManager.shared()!
        let state = TrackingActivityAttributes.ContentState(
            isTrip: gl.tripInProgress(), lastSent: gl.lastSentDate,
            appearance: TrackingActivityAttributes.Appearance(rawValue: appearance) ?? .minimal,
            reminderDeadline: reminderDeadline
        )
        let content = ActivityContent(state: state, staleDate: reminderDeadline)
        if let activity {
            let structuralChange = lastContent?.appearance != state.appearance || lastContent?.isTrip != state.isTrip
                || lastContent?.reminderDeadline != state.reminderDeadline
            // Send Every can be one second; the status surface does not need that update rate.
            if lastContent != state && (structuralChange || Date().timeIntervalSince(lastUpdate) >= 30) {
                await activity.update(content)
                guard self.activity?.id == activity.id else { return }
                lastContent = state
                lastUpdate = Date()
            }
            activityStatus = state.appearance == .blank ? "Active · blank layout requested" : "Active"
            return
        }
        guard !suppressed else {
            activityStatus = "Ended or dismissed · reopen the app or retry"
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            activityStatus = "Open Overland to start the Live Activity"
            return
        }
        do {
            let newActivity = try Activity.request(attributes: TrackingActivityAttributes(startedAt: Date()),
                                                   content: content, pushType: nil)
            observe(newActivity)
            lastContent = state
            lastUpdate = Date()
            activityStatus = state.appearance == .blank ? "Active · blank layout requested" : "Active"
        } catch {
            suppressed = true
            activityStatus = "Could not start: \(error.localizedDescription)"
        }
    }

    private func endActivities() async {
        activityObserver?.cancel()
        activityObserver = nil
        activity = nil
        lastContent = nil
        for old in Activity<TrackingActivityAttributes>.activities {
            await old.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func observe(_ activity: Activity<TrackingActivityAttributes>) {
        self.activity = activity
        activityObserver?.cancel()
        activityObserver = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled, let self, self.activity?.id == activity.id else { return }
                if state == .dismissed || state == .ended {
                    self.activity = nil
                    self.suppressed = true
                    self.activityStatus = "Ended or dismissed · reopen the app or retry"
                    return
                }
            }
        }
    }
}
