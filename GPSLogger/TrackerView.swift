import SwiftUI
import MapKit

struct TrackerView: View {
    @State private var confirmingStop = false
    @State private var bridge = GLManagerBridge.shared
    @State private var camera = MapCameraPosition.userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $camera) { UserAnnotation { CurrentLocationMarker() } }
            .mapControls {
                MapUserLocationButton()
            }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            VStack(spacing: 8) {
                hud
                controls.padding(.horizontal)
            }
        }
        .overlay(alignment: .topTrailing) {
            speedometer
                .padding(.trailing, 14)
                .padding(.top, 6)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: bridge.lastLocationText) { _, newValue in
            guard newValue != "–" else { return }
            camera = .userLocation(fallback: .automatic)
        }
        .confirmStopTracking($confirmingStop) { bridge.trackingOn = false }
        .onAppear { bridge.refresh() }
    }

    private var speedometer: some View {
        VStack(spacing: 2) {
            Text("SPEED")
                .font(.caption2.weight(.semibold))
            Text("\(bridge.speed)")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(bridge.speedUnit)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(minWidth: 72)
        .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.black, lineWidth: 2)
                .padding(5)
        }
        .glassPanel(cornerRadius: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed \(bridge.speed) \(bridge.speedUnit)")
    }

    private var hud: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                stat("AGE", value: Text(bridge.lastLocationAge), caption: "minutes ago")
                stat("LOCATION", value: Text(bridge.lastLocationText), caption: bridge.lastAccuracyText, small: true)

            }
            Divider()
            HStack {
                Text("QUEUED").font(.caption2).foregroundStyle(.secondary)
                Text("\(bridge.queueCount)")
                    .font(.caption.monospacedDigit())
                Spacer()
                Text("LAST SENT").font(.caption2).foregroundStyle(.secondary)
                Text(bridge.lastSentText)
                    .font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 4)
            sendIntervalRow
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .glassPanel(cornerRadius: 24)
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private var sendIntervalRow: some View {
        SliderRow(title: "Send Every", value: $bridge.sendIntervalValue,
                  range: 0...3600, offBelow: 1, unit: "seconds", format: SettingFormat.seconds)
            .font(.caption)
    }

    private func stat(_ title: String, value: Text, caption: String, small: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            value
                .font(small ? .callout.monospacedDigit() : .title3.monospacedDigit())
                .multilineTextAlignment(.center)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                if bridge.trackingEnabled {
                    confirmingStop = true
                } else {
                    bridge.trackingOn = true
                }
                bridge.refresh()
            } label: {
                Label(bridge.trackingEnabled ? "Stop Tracking" : "Start Tracking",
                      systemImage: bridge.trackingEnabled ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .glassButtonStyle(prominent: true, tint: bridge.trackingEnabled ? .red : .blue)

            Button {
                GLManager.shared().sendQueueNow()
            } label: {
                Label(bridge.sending ? "Sending…" : "Send Now", systemImage: "paperplane.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .glassButtonStyle(tint: .blue)
            .disabled(!bridge.endpointSet || bridge.sending || bridge.queueCount == 0)
        }
        .padding(.bottom, 4)
    }
}
