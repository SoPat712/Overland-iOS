import SwiftUI

struct TripSettingsView: View {
    @State private var bridge = GLManagerBridge.shared

    var body: some View {
        Form {
            Section {
                Picker("Accuracy Preset", selection: $bridge.tripAccuracyPreset) {
                    Text("Custom").tag(0)
                    Text("Best").tag(1)
                    Text("Navigation").tag(2)
                }
                if bridge.tripAccuracyPreset == 0 {
                    SliderRow(title: "Desired Accuracy", value: $bridge.tripAccuracyMeters, range: 5...3000, unit: "meters", format: SettingFormat.meters)
                }
                Picker("Activity Type", selection: $bridge.tripActivityIndex) {
                    Text("Other").tag(0)
                    Text("Automotive").tag(1)
                    Text("Fitness").tag(2)
                    Text("Navigation").tag(3)
                    Text("Airborne").tag(4)
                }
            } header: {
                SettingsSectionHeader(title: "Accuracy", topic: .precision)
            } footer: {
                Text("Applied only while a trip is in progress.")
            }

            Section {
                Picker("Logging Mode", selection: $bridge.tripLoggingModeIndex) {
                    Text("All Data").tag(0)
                    Text("Only Latest").tag(1)
                    Text("OwnTracks").tag(2)
                }
                SliderRow(title: "Locations per Batch", value: $bridge.tripBatchValue, range: 1...1000, format: SettingFormat.count)
            } header: {
                SettingsSectionHeader(title: "Batching", topic: .batching)
            }

            Section {
                SliderRow(title: "Min Distance Between Points", value: $bridge.tripDiscardDistanceMeters, range: 0...1000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                SliderRow(title: "Min Time Between Points", value: $bridge.tripDiscardSecondsValue, range: 0...600, offBelow: 1, unit: "seconds", format: SettingFormat.seconds)
            } header: {
                SettingsSectionHeader(title: "Discard Filters", topic: .precision)
            } footer: {
                Text("Skip points that are too close together in space or time to add detail.")
            }

            Section {
                Toggle("Show Background Indicator", isOn: $bridge.tripBackgroundIndicator)
                Toggle("Pause Updates Automatically", isOn: $bridge.tripPausesAutomatically)
                if bridge.tripPausesAutomatically {
                    SliderRow(title: "Resume After Moving", value: $bridge.resumeDistanceMeters, range: 0...2000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                }
            } header: {
                SettingsSectionHeader(title: "Privacy", topic: .stationary)
            } footer: {
                Text("The resume distance is shared with normal tracking. Turning off automatic pausing also disables resuming on movement.")
            }

            Section {
                Toggle("Prevent Screen Lock", isOn: $bridge.screenLock)
            } header: {
                SettingsSectionHeader(title: "Screen", topic: .trip)
            } footer: {
                Text("Keeps the screen on while a trip is in progress.")
            }
        }
        .tabBarClearance()
        .navigationTitle("Trip Settings")
        .onAppear { bridge.refresh() }
    }
}
