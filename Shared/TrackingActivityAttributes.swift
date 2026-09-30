import ActivityKit
import Foundation

struct TrackingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isTrip: Bool
        var lastSent: Date?
        var appearance: Appearance
        var reminderDeadline: Date?
    }

    enum Appearance: String, Codable, CaseIterable {
        case status
        case minimal
        case blank
    }

    var startedAt: Date
}
