import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TrackingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrackingActivityAttributes.self) { context in
            Group {
                if context.isStale {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Open Overland", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(.orange)
                        Text("Location updates were stopped. Launch the app to resume.")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                } else {
                    emptyContent
                }
            }
            .activityBackgroundTint(context.isStale ? nil : .clear)
            .widgetURL(URL(string: "overland://tracker"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    if context.isStale {
                        VStack(spacing: 4) {
                            Label("Open Overland", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Location updates were stopped. Launch the app to resume.")
                                .font(.caption)
                        }
                    } else if context.state.appearance == .blank {
                        emptyContent
                    } else {
                        VStack(spacing: 4) {
                            Label(context.state.isTrip ? "Recording trip" : "Tracking on", systemImage: "location.fill")
                            if context.state.appearance == .status {
                                if let sent = context.state.lastSent {
                                    Text("Last sent \(sent, style: .relative) ago").font(.caption)
                                } else {
                                    Text("No successful send yet").font(.caption)
                                }
                            }
                        }
                    }
                }
            } compactLeading: {
                if context.isStale {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if context.state.appearance == .blank {
                    emptyContent
                } else {
                    Image(systemName: "location.fill").foregroundStyle(.blue)
                }
            } compactTrailing: {
                if context.isStale { Text("Open").font(.caption) }
                else if context.state.appearance == .status { Text("On").font(.caption) }
                else { emptyContent }
            } minimal: {
                if context.isStale {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if context.state.appearance == .blank {
                    emptyContent
                } else {
                    Image(systemName: "location.fill").foregroundStyle(.blue)
                }
            }
            .widgetURL(URL(string: "overland://tracker"))
        }
    }

    // iOS may retain its surface even with transparent, zero-sized content.
    private var emptyContent: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
    }
}
