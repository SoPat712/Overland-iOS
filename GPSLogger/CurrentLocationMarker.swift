import SwiftUI

struct CurrentLocationMarker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mapPageActive) private var pageActive
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        ZStack {
            Circle().fill(.blue.opacity(0.12)).frame(width: 36, height: 36)
            if pageActive && scenePhase == .active && !reduceMotion && !lowPower {
                LocationPulse()
            }
            Circle()
                .fill(.blue)
                .frame(width: 16, height: 16)
                .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
        .frame(width: 48, height: 48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current location")
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

private struct LocationPulse: View {
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(.blue.opacity(expanded ? 0 : 0.45), lineWidth: 2)
            .frame(width: 44, height: 44)
            .scaleEffect(expanded ? 1 : 0.4)
            .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false), value: expanded)
            .onAppear { expanded = true }
            .accessibilityHidden(true)
    }
}

private struct MapPageActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var mapPageActive: Bool {
        get { self[MapPageActiveKey.self] }
        set { self[MapPageActiveKey.self] = newValue }
    }
}
