import SwiftUI

struct EndpointView: View {
    @State private var url = ""
    @State private var token = ""
    @State private var deviceId = ""
    @State private var uniqueId = false
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                TextField("https://server.example.com/api", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Server URL")
            } footer: {
                if !url.isEmpty && !validURL {
                    Text("Not a valid http(s) URL").foregroundStyle(.red)
                }
            }
            Section("Authentication") {
                SecureField("Access Token", text: $token)
                TextField("Device ID", text: $deviceId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Include unique_id", isOn: $uniqueId)
            }
            Section {
                Button("Save") {
                    GLManager.shared().saveNewAPIEndpoint(url, andAccessToken: token)
                    GLManager.shared().saveNewDeviceId(deviceId)
                    UserDefaults.standard.set(uniqueId, forKey: GLIncludeUniqueIdDefaultsName)
                    saved = true
                }
                .disabled(url.isEmpty || !validURL)
                .frame(maxWidth: .infinity)
                .glassButtonStyle(prominent: true, tint: .green)
                Button("Clear Server URL", role: .destructive) {
                    GLManager.shared().saveNewAPIEndpoint(nil, andAccessToken: nil)
                    url = ""
                    token = ""
                    saved = true
                }
                .frame(maxWidth: .infinity)
            }
            if saved {
                Section { Text("Saved").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Endpoint")
        .onAppear(perform: load)
    }

    private var validURL: Bool {
        URL(string: url)?.scheme.map { $0 == "http" || $0 == "https" } ?? false
    }

    private func load() {
        guard let gl = GLManager.shared() else { return }
        url = gl.apiEndpointURL() ?? ""
        token = gl.apiAccessToken() ?? ""
        deviceId = gl.deviceId() ?? ""
        uniqueId = UserDefaults.standard.bool(forKey: GLIncludeUniqueIdDefaultsName)
    }
}
