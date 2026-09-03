import SwiftUI

struct SettingsView: View {
    @State private var bridge = GLManagerBridge.shared

    var body: some View {
        Form {
            Section {
                NavigationLink("Server URL") { EndpointView() }
            }
            Section("Tracking") {
                Toggle("Tracking Enabled", isOn: $bridge.trackingOn)
                Picker("Continuous Tracking Mode", selection: $bridge.trackingModeIndex) {
                    Text("Off").tag(0)
                    Text("Standard").tag(1)
                    Text("Significant").tag(2)
                    Text("Both").tag(3)
                }
                Toggle("Visit Tracking", isOn: $bridge.visitTracking)
            }
            Section("Location Accuracy") {
                Picker("Desired Accuracy", selection: $bridge.accuracyIndex) {
                    Text("Nav").tag(0)
                    Text("Best").tag(1)
                    Text("10m").tag(2)
                    Text("100m").tag(3)
                    Text("1km").tag(4)
                    Text("3km").tag(5)
                }
                Picker("Activity Type", selection: $bridge.activityIndex) {
                    Text("Other").tag(0)
                    Text("Car").tag(1)
                    Text("Fitness").tag(2)
                    Text("Nav").tag(3)
                    Text("Air").tag(4)
                }
                Toggle("Show Background Indicator", isOn: $bridge.backgroundIndicator)
                Toggle("Pause Updates Automatically", isOn: $bridge.pausesAutomatically)
            }
            Section {
                Picker("Logging Mode", selection: $bridge.loggingModeIndex) {
                    Text("All Data").tag(0)
                    Text("Only Latest").tag(1)
                    Text("Owntracks").tag(2)
                }
                Picker("Locations per Batch", selection: $bridge.batchIndex) {
                    ForEach(Array([50, 100, 200, 500, 1000].enumerated()), id: \.offset) { i, n in
                        Text("\(n)").tag(i)
                    }
                }
            }
            Section("Discard Filters") {
                Picker("Min Distance Between Points", selection: $bridge.discardDistanceIndex) {
                    Text("Off").tag(0)
                    Text("1m").tag(1)
                    Text("10m").tag(2)
                    Text("50m").tag(3)
                    Text("100m").tag(4)
                    Text("500m").tag(5)
                }
                Picker("Min Time Between Points", selection: $bridge.discardSecondsIndex) {
                    Text("Off").tag(0)
                    Text("5s").tag(1)
                    Text("10s").tag(2)
                    Text("30s").tag(3)
                    Text("1m").tag(4)
                    Text("2m").tag(5)
                }
                Picker("Max Accuracy of Points", selection: $bridge.discardAccuracyIndex) {
                    Text("Off").tag(0)
                    Text("10m").tag(1)
                    Text("50m").tag(2)
                    Text("100m").tag(3)
                    Text("500m").tag(4)
                    Text("1000m").tag(5)
                }
            }
            Section("Stop Updates When Stationary") {
                Picker("Stop Updates if within Radius", selection: $bridge.stopRadiusIndex) {
                    Text("Off").tag(0)
                    Text("10m").tag(1)
                    Text("20m").tag(2)
                    Text("50m").tag(3)
                    Text("100m").tag(4)
                    Text("200m").tag(5)
                }
                Picker("Stop Updates after", selection: $bridge.stopAfterIndex) {
                    Text("1min").tag(0)
                    Text("2min").tag(1)
                    Text("5min").tag(2)
                    Text("10min").tag(3)
                    Text("20min").tag(4)
                }
            }
            Section("WiFi Zones") {
                NavigationLink("Configure WiFi Zones") { WifiZoneListView() }
            }
            Section {
                Toggle("Enable Notifications", isOn: $bridge.notifications)
            }
            Section("Support") {
                Button("Tip Jar") { presentLegacy("TipJarViewController") }
                Link("Privacy Policy", destination: URL(string: "https://overland.p3k.app/privacy")!)
            }
        }
        .navigationTitle("Settings")
        .onAppear { bridge.refresh() }
    }

    private func presentLegacy(_ identifier: String) {
        let vc = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: identifier)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.first?.windows.first(where: \.isKeyWindow)?.rootViewController
        root?.present(UINavigationController(rootViewController: vc), animated: true)
    }
}

