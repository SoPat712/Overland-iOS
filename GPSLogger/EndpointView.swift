import SwiftUI

struct EndpointView: View {
    @State private var url = ""
    @State private var token = ""
    @State private var deviceId = ""
    @State private var uniqueId = false
    @State private var saved = false
    @State private var acceptHTTP = false
    @State private var headers: [HeaderField] = []
    @State private var bridge = GLManagerBridge.shared

    private var configured: Bool { bridge.endpointSet }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    Label(configured ? "Configured" : "Not Configured",
                          systemImage: configured ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(configured ? .green : .orange)
                        .font(.callout)
                }
                if configured {
                    HStack {
                        Text("Endpoint")
                        Spacer()
                        Text(GLManager.shared().apiEndpointURL() ?? "")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                }
                if bridge.sending {
                    Label("Sending…", systemImage: "arrow.up.circle")
                }
                sendChart
            } header: {
                SettingsSectionHeader(title: "Connection", topic: .server)
            }

            Section {
                TextField("https://server.example.com/api", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                SettingsSectionHeader(title: "Server Endpoint", topic: .server)
            } footer: {
                if !url.isEmpty && !validURL {
                    Text("Not a valid http(s) URL").foregroundStyle(.red)
                }
            }

            Section {
                SecureField("Access Token", text: $token)
                TextField("Device ID", text: $deviceId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Include unique_id", isOn: $uniqueId)
            } header: {
                SettingsSectionHeader(title: "Authentication", topic: .server)
            } footer: {
                Text("The access token is sent in the Authorization header. Device ID is included in location data. OwnTracks expects a Base64-encoded username:password token.")
            }

            Section {
                ForEach($headers) { $header in
                    VStack(alignment: .leading) {
                        TextField("Header name", text: $header.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Value", text: $header.value)
                        Button("Remove Header", role: .destructive) {
                            headers.removeAll { $0.id == header.id }
                        }
                        .font(.caption)
                    }
                }
                Button("Add Header") { headers.append(HeaderField()) }
            } header: {
                SettingsSectionHeader(title: "Custom HTTP Headers", topic: .server)
            } footer: {
                Text(headersValid ? "Sent with each request, including authentication required by a reverse proxy." : "Use unique HTTP header names and values without line breaks. Host, Content-Length, Connection, Transfer-Encoding, and Authorization are reserved.")
                    .foregroundStyle(headersValid ? Color.secondary : .red)
            }

            Section {
                Toggle("Accept Any Successful HTTP Response", isOn: $acceptHTTP)
            } footer: {
                Text("Enable for OwnTracks or servers that return an empty response. Otherwise, the server must acknowledge the upload with a JSON result of ok.")
            }

            Section {
                Button("Save") {
                    bridge.saveServer(url: url, token: token, deviceId: deviceId, uniqueId: uniqueId,
                                      acceptHTTP: acceptHTTP, headers: Dictionary(uniqueKeysWithValues: headers.map { ($0.name, $0.value) }))
                    saved = true
                }
                .disabled(!validURL || !headersValid)
                .frame(maxWidth: .infinity)
                Button("Clear Server URL", role: .destructive) {
                    bridge.clearServer()
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
        .tabBarClearance()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onChange(of: url) { _, _ in saved = false }
        .onChange(of: token) { _, _ in saved = false }
        .onChange(of: deviceId) { _, _ in saved = false }
        .onChange(of: uniqueId) { _, _ in saved = false }
        .onChange(of: acceptHTTP) { _, _ in saved = false }
        .onChange(of: headers) { _, _ in saved = false }
        .onAppear {
            load()
            bridge.refresh()
        }
    }

    private var sendChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Sends · This Session")
                .font(.subheadline)
            if bridge.sendHistory.isEmpty {
                Text("No sends yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 2) {
                    ForEach(bridge.sendHistory) { entry in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color(for: entry.kind))
                            .frame(maxWidth: .infinity)
                            .frame(height: 18)
                            .accessibilityLabel("\(entry.date.formatted(date: .omitted, time: .standard)): \(statusLabel(entry.kind))")
                    }
                }
                HStack(spacing: 12) {
                    legend(.green, "OK")
                    legend(.orange, "Rejected")
                    legend(.red, "Network")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for kind: SendStatusEntry.Kind) -> Color {
        switch kind {
        case .success: return .green
        case .server: return .orange
        case .network: return .red
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    private var validURL: Bool {
        GLManager.isValidEndpoint(url)
    }

    private func load() {
        guard let gl = GLManager.shared() else { return }
        url = gl.apiEndpointURL() ?? ""
        token = gl.apiAccessToken() ?? ""
        deviceId = gl.deviceId() ?? ""
        uniqueId = UserDefaults.standard.bool(forKey: GLIncludeUniqueIdDefaultsName)
        acceptHTTP = UserDefaults.standard.bool(forKey: GLConsiderHTTP200SuccessDefaultsName)
        headers = (gl.customHTTPHeaders ?? [:]).sorted { $0.key < $1.key }.map { HeaderField(name: $0.key, value: $0.value) }
        saved = false
    }

    private var headersValid: Bool {
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var names = Set<String>()
        for header in headers {
            let name = header.name.lowercased()
            if name.isEmpty || !header.name.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return false }
            if ["host", "content-length", "connection", "transfer-encoding", "authorization"].contains(name) { return false }
            if !names.insert(name).inserted || header.value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { return false }
        }
        return true
    }

    private func statusLabel(_ kind: SendStatusEntry.Kind) -> String {
        switch kind {
        case .success: return "Success"
        case .server: return "Server rejected the upload"
        case .network: return "Network failure"
        }
    }
}

private struct HeaderField: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var value = ""
}
