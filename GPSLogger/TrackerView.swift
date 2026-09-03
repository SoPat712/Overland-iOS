import SwiftUI
import MapKit

struct TrackerView: View {
    @State private var bridge = GLManagerBridge.shared
    @State private var camera = MapCameraPosition.userLocation(fallback: .automatic)
    @State private var showEndpointPrompt = false

    var body: some View {
        ZStack {
            Map(position: $camera)
                .ignoresSafeArea(edges: .bottom)

            VStack {
                Spacer()
                hud
                controls.padding(.horizontal)
            }
        }
        .navigationTitle("Overland")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    EndpointView()
                } label: {
                    Image(systemName: bridge.endpointSet ? "antenna.radiowaves.left.and.right" : "exclamationmark.triangle")
                }
                .accessibilityLabel("Endpoint")
            }
        }
        .onAppear { bridge.refresh() }
    }

    private var hud: some View {
        HStack(spacing: 24) {
            stat("AGE", value: Text(bridge.lastLocationAge), caption: "minutes ago")
            stat("LOCATION", value: Text(bridge.lastLocationText), caption: bridge.lastAccuracyText, small: true)
            stat("SPEED", value: Text("\(bridge.speed)"), caption: bridge.speedUnit)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 24).fill(.ultraThinMaterial)
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private func stat(_ title: String, value: Text, caption: String, small: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            value
                .font(small ? .callout.monospacedDigit() : .title3.monospacedDigit())
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                if bridge.trackingEnabled {
                    GLManager.shared().stopAllUpdates()
                } else {
                    GLManager.shared().startAllUpdates()
                }
                bridge.refresh()
            } label: {
                Label(bridge.trackingEnabled ? "Stop" : "Start",
                      systemImage: bridge.trackingEnabled ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .glassButtonStyle(prominent: true, tint: bridge.trackingEnabled ? .red : .green)

            Button {
                GLManager.shared().sendQueueNow()
            } label: {
                Label(bridge.sending ? "Sending…" : "Send Now", systemImage: "paperplane.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .glassButtonStyle(tint: .green)
            .disabled(!bridge.endpointSet)
        }
        .padding(.bottom, 4)
    }
}
