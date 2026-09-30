import ActivityKit
import AVFoundation
import CoreLocation
import UserNotifications
import XCTest
@testable import Overland

final class BackgroundRuntimeTests: XCTestCase {
    @MainActor func testSilentAudioStartsOnlyWhenEnabledAndStops() async throws {
        let audio = SilentAudioSession()
        audio.refresh()
        XCTAssertFalse(audio.isPlaying)
        audio.setEnabled(true)
        try await waitUntil { audio.isPlaying }
        XCTAssertTrue(audio.isPlaying, audio.status)
        audio.setEnabled(false)
        try await waitUntil { audio.status == "Off" }
        XCTAssertFalse(audio.isPlaying)
        audio.refresh()
        XCTAssertFalse(audio.isPlaying)
    }

    @MainActor func testInterruptionRequiresResumePermission() async throws {
        let audio = SilentAudioSession()
        defer { audio.setEnabled(false) }
        audio.setEnabled(true)
        try await waitUntil { audio.isPlaying }
        XCTAssertTrue(audio.isPlaying, audio.status)
        interrupt(.began)
        try await waitUntil { !audio.isPlaying }
        XCTAssertFalse(audio.isPlaying)
        audio.refresh()
        XCTAssertFalse(audio.isPlaying)
        interrupt(.ended)
        try await waitUntil { audio.status == "Silent audio paused after an interruption" }
        audio.refresh()
        XCTAssertFalse(audio.isPlaying)
        audio.retry()
        try await waitUntil { audio.isPlaying }
        XCTAssertTrue(audio.isPlaying, audio.status)
        audio.setEnabled(false)
        try await waitUntil { audio.status == "Off" }
    }

    @MainActor func testAuthorizedResumeRestartsEnabledAudio() async throws {
        let audio = SilentAudioSession()
        defer { audio.setEnabled(false) }
        audio.setEnabled(true)
        try await waitUntil { audio.isPlaying }
        interrupt(.began)
        try await waitUntil { !audio.isPlaying }
        interrupt(.ended, options: .shouldResume)
        try await waitUntil { audio.isPlaying }
        XCTAssertTrue(audio.isPlaying, audio.status)
        audio.setEnabled(false)
        try await waitUntil { audio.status == "Off" }
    }

    @MainActor func testStoppingDuringInterruptionPreventsResume() async throws {
        let audio = SilentAudioSession()
        audio.setEnabled(true)
        try await waitUntil { audio.isPlaying }
        interrupt(.began)
        try await waitUntil { !audio.isPlaying }
        audio.setEnabled(false)
        try await waitUntil { audio.status == "Off" }
        interrupt(.ended, options: .shouldResume)
        audio.retry()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(audio.isPlaying)
    }

    @MainActor func testExplicitRetryRecoversFromMissingInterruptionEnd() async throws {
        let audio = SilentAudioSession()
        defer { audio.setEnabled(false) }
        audio.setEnabled(true)
        try await waitUntil { audio.isPlaying }
        interrupt(.began)
        try await waitUntil { !audio.isPlaying }
        audio.refresh()
        XCTAssertFalse(audio.isPlaying)
        audio.retry()
        try await waitUntil { audio.isPlaying }
        XCTAssertTrue(audio.isPlaying, audio.status)
        audio.setEnabled(false)
        try await waitUntil { audio.status == "Off" }
    }

    @MainActor func testLiveActivityAndAudioFollowTracking() async throws {
        try await withTrackingActivity { activity in
            let runtime = OverlandBackgroundRuntime.shared
            runtime.appearance = "blank"
            try await waitUntil { activity.content.state.appearance == .blank }
            runtime.silentAudioEnabled = true
            try await waitUntil { runtime.audioStatus == "Silent audio active" }
        }
    }

    @MainActor func testLiveActivityFollowsScheduledReminder() async throws {
        guard ProcessInfo.processInfo.environment["OVERLAND_NOTIFICATION_INTEGRATION"] == "1" else {
            throw XCTSkip("Enable OVERLAND_NOTIFICATION_INTEGRATION with notifications approved to test the system reminder service.")
        }
        try await withTrackingActivity { activity in
            let center = UNUserNotificationCenter.current()
            let notification = UNMutableNotificationContent()
            notification.body = "Location updates were stopped. Launch the app to resume."
            try await center.add(UNNotificationRequest(identifier: "reminder", content: notification,
                                 trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)))
            NotificationCenter.default.post(name: Notification.Name(GLReminderChangedNotification), object: nil)
            try await waitUntil { activity.content.staleDate != nil }
            let requests = await center.pendingNotificationRequests()
            let trigger = try XCTUnwrap(requests.first { $0.identifier == "reminder" }?.trigger as? UNTimeIntervalNotificationTrigger)
            let deadline = try XCTUnwrap(trigger.nextTriggerDate())
            XCTAssertEqual(try XCTUnwrap(activity.content.staleDate).timeIntervalSince1970,
                           deadline.timeIntervalSince1970, accuracy: 1)
            center.removePendingNotificationRequests(withIdentifiers: ["reminder"])
            NotificationCenter.default.post(name: Notification.Name(GLReminderChangedNotification), object: nil)
            try await waitUntil { activity.content.staleDate == nil }
        }
    }

    @MainActor private func withTrackingActivity(_ body: (Activity<TrackingActivityAttributes>) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        let manager = GLManager.shared()!
        let runtime = OverlandBackgroundRuntime.shared
        manager.stopAllUpdates()
        defer {
            manager.stopAllUpdates()
            defaults.setPersistentDomain(saved, forName: domain)
        }
        guard manager.locationManager.authorizationStatus == .authorizedAlways else {
            throw XCTSkip("Grant location-always on the disposable test simulator before this integration test.")
        }
        defaults.set(false, forKey: "GLNotificationsEnabledDefaults")
        defaults.set(1, forKey: "GLSignificantLocationModeDefaults")
        defaults.set(-1, forKey: "GLSendIntervalDefaults")
        runtime.silentAudioEnabled = false
        runtime.liveActivityEnabled = true
        manager.startAllUpdates()
        try await waitUntil { !Activity<TrackingActivityAttributes>.activities.isEmpty }
        let activity = try XCTUnwrap(Activity<TrackingActivityAttributes>.activities.first)
        try await body(activity)
        manager.stopAllUpdates()
        try await waitUntil { Activity<TrackingActivityAttributes>.activities.isEmpty }
        try await waitUntil { runtime.audioStatus == "Off" }
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out waiting for background runtime state")
        throw NSError(domain: "BackgroundRuntimeTests", code: 1)
    }

    @MainActor private func interrupt(_ type: AVAudioSession.InterruptionType,
                                      options: AVAudioSession.InterruptionOptions = []) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                                                   AVAudioSessionInterruptionOptionKey: options.rawValue])
    }
}
