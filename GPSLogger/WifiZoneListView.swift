import SwiftUI

struct WifiZoneListView: View {
    @State private var zones: [[String: String]] = []
    @State private var showingAddZone = false

    var body: some View {
        List {
            if zones.isEmpty {
                Text("When connected to a matching network, this location is used instead of GPS.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(zones.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(zones[i]["name"] ?? "")
                        .font(.headline)
                    if let bssid = zones[i]["bssid"] { Text(bssid).font(.caption).foregroundStyle(.secondary) }
                    Text("\(zones[i]["latitude"] ?? "0"), \(zones[i]["longitude"] ?? "0")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                for i in offsets.sorted(by: >) {
                    GLManager.shared().removeWifiZone(at: i)
                }
                reload()
            }
        }
        .navigationTitle("WiFi Zones")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SettingsHelpButton(topic: .automation)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddZone = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Zone")
            }
        }
        .sheet(isPresented: $showingAddZone) {
            AddWifiZoneView(onSave: reload)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        zones = GLManager.shared().wifiZones
    }
}

struct AddWifiZoneView: View {
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bssid = ""
    @State private var latitude = ""
    @State private var longitude = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Network") {
                    TextField("WiFi network name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("BSSID (optional)", text: $bssid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let ssid = currentSSID {
                        Button("Use current network (\(ssid))") {
                            name = ssid
                            bssid = currentBSSID ?? ""
                        }
                    }
                }
                Section("Location") {
                    TextField("Latitude", text: $latitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Longitude", text: $longitude)
                        .keyboardType(.numbersAndPunctuation)
                    if let loc = GLManager.shared().lastLocation {
                        Button("Use current location") {
                            latitude = String(format: "%.5f", loc.coordinate.latitude)
                            longitude = String(format: "%.5f", loc.coordinate.longitude)
                        }
                    }
                }
            }
            .navigationTitle("Add Zone")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        GLManager.shared().addWifiZone(withName: name,
                                                              latitude: latitude,
                                                              longitude: longitude,
                                                              bssid: bssid.isEmpty ? nil : bssid)
                        onSave()
                        dismiss()
                    }
                    .disabled(!validZone)
                }
            }
        }
    }

    private var validZone: Bool {
        guard !name.isEmpty, let lat = Double(latitude), let lon = Double(longitude),
              lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else { return false }
        return bssid.isEmpty || bssid.range(of: "^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", options: .regularExpression) != nil
    }

    private var currentSSID: String? {
        let info = GLManager.currentWifiNetworkInfo() as? [String: String]
        return info?["SSID"].flatMap { $0.isEmpty ? nil : $0 }
    }

    private var currentBSSID: String? {
        (GLManager.currentWifiNetworkInfo() as? [String: String])?["BSSID"]
    }
}

final class WifiZoneLauncher: NSObject {
    @objc static func present(from viewController: UIViewController) {
        let hosting = UIHostingController(rootView: WifiZoneListView())
        viewController.present(UINavigationController(rootViewController: hosting), animated: true)
    }
}
