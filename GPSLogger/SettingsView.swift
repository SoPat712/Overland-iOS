import SwiftUI

struct SettingsView: View {
    @State private var confirmingStop = false
    @State private var bridge = GLManagerBridge.shared

    var body: some View {
        Form {
            Section {
                Picker("Usage Preset", selection: $bridge.usageProfile) {
                    Text("Custom").tag(0)
                    Text("High Resolution").tag(1)
                    Text("Low Power").tag(2)
                    Text("Balanced").tag(3)
                    Text("Walking / Running").tag(4)
                    Text("Driving").tag(5)
                }
                .disabled(bridge.tripInProgress)
            } header: {
                SettingsSectionHeader(title: "Usage Preset", topic: .presets)
            } footer: {
                Text(bridge.tripInProgress ? "Finish the current trip before applying a preset." : profileDescription + " Changes normal tracking settings immediately. Server, logging format and sending are kept. The resume distance is shared with trips. Tap ⓘ for the exact values and sources.")
            }

            Section {
                LabeledContent("Location Access", value: bridge.locationPermission)
                if bridge.locationPermission == "Not Determined" {
                    Button("Allow Location Access") { bridge.requestLocationPermission() }
                } else if bridge.locationPermission == "When in Use" {
                    Button("Allow Background Location") { bridge.requestLocationPermission() }
                }
                Link("Open iOS Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
            } header: {
                SettingsSectionHeader(title: "Permissions", topic: .permissions)
            } footer: {
                Text("Always access allows location recording when the app is in the background. You can also manage Precise Location in iOS Settings.")
            }

            Section {
                Toggle("Tracking Enabled", isOn: Binding(
                    get: { bridge.trackingOn },
                    set: { enabled in
                        if enabled { bridge.trackingOn = true } else { confirmingStop = true }
                    }
                ))
                Picker("Update Mode", selection: $bridge.trackingModeIndex) {
                    Text("Off").tag(0)
                    Text("Standard").tag(1)
                    Text("Significant").tag(2)
                    Text("Both").tag(3)
                }
                Toggle("Visit Tracking", isOn: $bridge.visitTracking)
            } header: {
                SettingsSectionHeader(title: "Tracking", topic: .tracking)
            } footer: {
                Text("Significant-change mode records larger movements while conserving battery. Visit tracking is controlled separately.")
            }

            Section {
                NavigationLink {
                    EndpointView()
                } label: {
                    Label("Server", systemImage: "antenna.radiowaves.left.and.right")
                }
            } header: {
                SettingsSectionHeader(title: "Server", topic: .server)
            } footer: {
                Text("Endpoint, authentication, and send status.")
            }

            Section {
                Picker("Accuracy Preset", selection: $bridge.accuracyPreset) {
                    Text("Custom").tag(0)
                    Text("Best").tag(1)
                    Text("Navigation").tag(2)
                }
                if bridge.accuracyPreset == 0 {
                    SliderRow(title: "Desired Accuracy", value: $bridge.accuracyMeters, range: 5...3000, unit: "meters", format: SettingFormat.meters)
                }
                Picker("Activity Type", selection: $bridge.activityIndex) {
                    Text("Other").tag(0)
                    Text("Automotive").tag(1)
                    Text("Fitness").tag(2)
                    Text("Navigation").tag(3)
                    Text("Airborne").tag(4)
                }
                SliderRow(title: "Min Distance Between Points", value: $bridge.discardDistanceMeters, range: 0...1000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                SliderRow(title: "Min Time Between Points", value: $bridge.discardSecondsValue, range: 0...600, offBelow: 1, unit: "seconds", format: SettingFormat.seconds)
                SliderRow(title: "Max Accuracy of Points", value: $bridge.discardAccuracyMeters, range: 0...5000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
            } header: {
                SettingsSectionHeader(title: "Precision", topic: .precision)
            } footer: {
                Text("Higher precision records more detail and uses more battery. Points closer together in space or time than the minimums are discarded.")
            }

            Section {
                SliderRow(title: "Stop Within Radius", value: $bridge.stopRadiusMeters, range: 0...1000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                    .disabled(bridge.trackingModeIndex != 3 || bridge.pausesAutomatically)
                SliderRow(title: "Stop After", value: $bridge.stopAfterValue, range: 30...3600, unit: "seconds", format: SettingFormat.seconds)
                    .disabled(bridge.trackingModeIndex != 3 || bridge.pausesAutomatically || bridge.stopRadiusMeters < 1)
                Toggle("Pause Updates Automatically", isOn: $bridge.pausesAutomatically)
                    .disabled(bridge.stopRadiusMeters >= 1)
                if bridge.pausesAutomatically {
                    SliderRow(title: "Resume After Moving", value: $bridge.resumeDistanceMeters, range: 0...2000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                }
            } header: {
                SettingsSectionHeader(title: "Stop When Stationary", topic: .stationary)
            } footer: {
                Text("In Both update mode, the radius and time pause standard updates until significant movement is detected. Automatic pausing lets iOS pause updates when stationary.")
            }

            Section {
                Picker("Logging Mode", selection: $bridge.loggingModeIndex) {
                    Text("All Data").tag(0)
                    Text("Only Latest").tag(1)
                    Text("OwnTracks").tag(2)
                }
                SliderRow(title: "Locations per Batch", value: $bridge.batchValue, range: 1...1000, format: SettingFormat.count)
                SliderRow(title: "Send Interval", value: $bridge.sendIntervalValue, range: 0...3600, offBelow: 1, unit: "seconds", format: SettingFormat.seconds)
            } header: {
                SettingsSectionHeader(title: "Batching", topic: .batching)
            } footer: {
                Text("Automatic sending runs as locations arrive after this interval. Set it to Off to send manually. Locations per Batch limits each request.")
            }

            Section {
                Toggle("Show Background Indicator", isOn: $bridge.backgroundIndicator)
            } header: {
                SettingsSectionHeader(title: "Background", topic: .background)
            }

            Section {
                NavigationLink("WiFi Zones") { WifiZoneListView() }
                Toggle("Notifications", isOn: $bridge.notifications)
            } header: {
                SettingsSectionHeader(title: "Automation", topic: .automation)
            } footer: {
                Text("Get notified when the tracker encounters problems sending data.")
            }

            Section {
                Button("Tip Jar") { presentLegacy("TipJarViewController") }
                Link("Privacy Policy", destination: URL(string: "https://overland.p3k.app/privacy")!)
            } header: {
                Text("Support")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .confirmStopTracking($confirmingStop) { bridge.trackingOn = false }
        .onAppear { bridge.refresh() }
    }

    private var profileDescription: String {
        switch bridge.usageProfile {
        case 1: return "Detailed routes: Standard, Best accuracy, no automatic pausing."
        case 2: return "Coarse history: significant changes controlled by iOS."
        case 3: return "Everyday history: Both, 100 m accuracy, stop within 50 m after 3 minutes."
        case 4: return "Walking or running: Standard, Best accuracy, Fitness activity."
        case 5: return "Detailed driving: Standard, Navigation accuracy, Automotive activity."
        default: return "Your current combination of settings. Choose a preset for a documented starting point."
        }
    }

    private func presentLegacy(_ identifier: String) {
        let vc = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: identifier)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.first?.windows.first(where: \.isKeyWindow)?.rootViewController
        root?.present(UINavigationController(rootViewController: vc), animated: true)
    }
}
