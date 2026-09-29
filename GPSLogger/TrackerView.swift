import SwiftUI

struct TrackerView: View {
    var history: HistoryPlaybackModel
    var onLive: () -> Void
    @State private var confirmingStop = false
    @State private var bridge = GLManagerBridge.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 8) {
            HistoryRuler(history: history, onLive: onLive)
            if history.isBrowsing {
                HistoryPlaybackView(history: history)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else {
                VStack(spacing: 8) {
                    overview
                    controls.padding(.horizontal)
                }
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: history.isBrowsing)
        .confirmStopTracking($confirmingStop) { bridge.trackingOn = false }
        .onAppear {
            bridge.refresh()
            history.reload()
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: bridge.trackingEnabled ? "location.circle.fill" : "location.slash.circle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(bridge.trackingEnabled ? .blue : .secondary)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bridge.trackingEnabled ? "Tracking on" : "Tracking paused")
                        .font(.headline)
                    Text(bridge.lastLocationAge == "–" ? "Waiting for a location" : "Updated \(bridge.lastLocationAge) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Current location", systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(bridge.lastLocationText == "–"
                         ? "No location yet"
                         : bridge.lastLocationText.replacingOccurrences(of: "\n", with: ", "))
                        .font(.subheadline.monospacedDigit())
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                if bridge.lastLocationText != "–" {
                    Text(bridge.lastAccuracyText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    deliveryMetric("Queued", value: bridge.queueCount.formatted(), icon: "tray.full")
                    deliveryMetric("Last sent", value: bridge.lastSentText, icon: "paperplane")
                }
            } else {
                HStack(spacing: 16) {
                    deliveryMetric("Queued", value: bridge.queueCount.formatted(), icon: "tray.full")
                    deliveryMetric("Last sent", value: bridge.lastSentText, icon: "paperplane")
                }
            }
            SliderRow(title: "Send Every", value: $bridge.sendIntervalValue,
                      range: 0...3600, offBelow: 1, unit: "seconds", format: SettingFormat.seconds)
                .font(.subheadline)
        }
        .padding(.top, 8)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }

    private func deliveryMetric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var controls: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    trackingButton
                    sendButton
                }
            } else {
                HStack(spacing: 12) {
                    trackingButton
                    sendButton
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var trackingButton: some View {
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
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.85)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .glassButtonStyle(prominent: !bridge.trackingEnabled, tint: bridge.trackingEnabled ? .red : .blue)
    }

    private var sendButton: some View {
        Button {
            GLManager.shared().sendQueueNow()
        } label: {
            Label(bridge.sending ? "Sending…" : "Send Now", systemImage: "paperplane.fill")
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.85)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .glassButtonStyle(tint: .blue)
        .disabled(!bridge.endpointSet || bridge.sending || bridge.queueCount == 0)
    }
}

struct TrackerSpeedometer: View {
    var replaySpeed: Double? = nil
    var isReplaying = false
    @State private var bridge = GLManagerBridge.shared

    private var displayedSpeed: String {
        guard isReplaying else { return "\(bridge.speed)" }
        guard let replaySpeed else { return "–" }
        let multiplier = bridge.speedUnit == "KM/H" ? 3.6 : 2.23694
        return "\(max(0, Int((replaySpeed * multiplier).rounded())))"
    }

    var body: some View {
        VStack(spacing: 2) {
            Text("SPEED")
                .font(.caption2.weight(.semibold))
            Text(displayedSpeed)
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
        .accessibilityLabel("\(isReplaying ? "Recorded" : "Current") speed \(displayedSpeed) \(bridge.speedUnit)")
    }
}
