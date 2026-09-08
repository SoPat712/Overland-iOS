import SwiftUI
import MapKit

struct TripView: View {
    @State private var bridge = GLManagerBridge.shared
    @State private var camera = MapCameraPosition.userLocation(fallback: .automatic)
    @State private var points: [[String: NSNumber]] = []
    @State private var scrubID: Int64?
    @State private var followingLive = true

    private let modes: [(String, String)] = [
        ("walk", "figure.walk"), ("run", "figure.run"), ("bicycle", "bicycle"), ("car", "car.fill"),
        ("taxi", "car.side"), ("bus", "bus.fill"), ("train", "tram.fill"), ("plane", "airplane"),
        ("boat", "sailboat.fill"), ("scooter", "scooter"), ("tram", "tram"),
        ("metro", "tram.tunnel.fill"), ("gondola", "cablecar.fill"), ("monorail", "tram.fill"), ("sleigh", "snowflake"),
    ]


    var body: some View {
        map
        .safeAreaInset(edge: .bottom, spacing: 8) {
            VStack(spacing: 8) {
                if bridge.tripInProgress {
                    scrubber
                }
                card
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TripSettingsView()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Trip Settings")
            }
        }
        .onAppear {
            bridge.refresh()
            reloadPoints()
        }
        .onChange(of: bridge.tick) { _, _ in
            if bridge.tripInProgress {
                reloadPoints()
            } else if !points.isEmpty {
                points = []
                scrubID = nil
                followingLive = true
            }
        }
    }

    // MARK: Map

    private var isLive: Bool { followingLive }

    private var scrubIndex: Int? {
        guard let scrubID else { return nil }
        return points.firstIndex { $0["id"]?.int64Value == scrubID }
    }

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation { CurrentLocationMarker() }
            if displayCoords.count > 1 {
                MapPolyline(coordinates: displayCoords)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if !isLive, let (coord, _) = scrubbedPoint {
                Marker("Trip point", systemImage: "mappin.circle.fill", coordinate: coord)
                    .tint(.blue)
            }
        }
        .mapControls {
            MapUserLocationButton()
        }
        .onChange(of: bridge.lastLocationText) { _, newValue in
            guard followingLive, newValue != "–" else { return }
            camera = .userLocation(fallback: .automatic)
        }
    }

    // MARK: Scrubber

    private var scrubber: some View {
        VStack(spacing: 8) {
            HStack {
                Text(isLive ? "Live" : timeLabel(scrubIndex) ?? "--:--:--")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isLive ? .green : .secondary)
                Spacer()
                if !isLive {
                    Button("Live") {
                        followingLive = true
                        scrubID = points.last?["id"]?.int64Value
                        camera = .userLocation(fallback: .automatic)
                    }
                    .font(.caption.bold())
                    .tint(.green)
                }
            }
            if points.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(points.indices, id: \.self) { i in
                            Button {
                                followingLive = false
                                scrubID = points[i]["id"]?.int64Value
                                focusScrub()
                            } label: { chip(i) }
                            .buttonStyle(.plain)
                            .id(points[i]["id"]?.int64Value ?? Int64(i))
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 4)
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: Binding(
                    get: { scrubID },
                    set: { id in
                        guard let id, id != scrubID else { return }
                        scrubID = id
                        if id != points.last?["id"]?.int64Value { followingLive = false }
                        if !followingLive { focusScrub() }
                    }
                ))
                .frame(height: 34)
            }
        }
        .padding(12)
        .glassPanel(cornerRadius: 20)
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private func chip(_ i: Int) -> some View {
        let selected = !isLive && scrubIndex == i
        let live = isLive && i == points.count - 1
        return Text(timeLabel(i) ?? "")
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(selected ? AnyShapeStyle(Color.blue.opacity(0.35)) : live ? AnyShapeStyle(Color.green.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(0.7)))
            }
            .foregroundStyle(selected || live ? .primary : .secondary)
    }

    // MARK: Trip card

    private var card: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                VStack(spacing: 2) {
                    Text("DISTANCE").font(.caption2).foregroundStyle(.secondary)
                    Text(distText).font(.title3.monospacedDigit())
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 2) {
                    Text("TIME").font(.caption2).foregroundStyle(.secondary)
                    Text(durationText).font(.title3.monospacedDigit())
                }
                .frame(maxWidth: .infinity)
            }

            HStack {
                Text("Travel Mode").font(.subheadline)
                Spacer()
                modePicker
            }

            if !bridge.tripInProgress {
                Text("Choose a travel mode, then start the trip. Your route is drawn on the map as points are recorded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                bridge.tripInProgress ? GLManager.shared().endTrip() : GLManager.shared().startTrip()
                scrubID = nil
                followingLive = true
                bridge.refresh()
                reloadPoints()
            } label: {
                Label(bridge.tripInProgress ? "Stop Trip" : "Start Trip",
                      systemImage: bridge.tripInProgress ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .glassButtonStyle(prominent: true, tint: bridge.tripInProgress ? .red : .blue)
        }
        .padding(16)
        .glassPanel(cornerRadius: 24)
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private var modePicker: some View {
        Picker("Travel Mode", selection: $bridge.tripMode) {
            ForEach(modes, id: \.0) { mode, icon in
                Label(mode.capitalized, systemImage: icon).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .tint(.primary)
        .font(.subheadline.weight(.medium))
        .disabled(bridge.tripInProgress)
    }

    // MARK: Data

    private var coords: [CLLocationCoordinate2D] {
        points.map {
            CLLocationCoordinate2D(
                latitude: $0["latitude"]?.doubleValue ?? 0,
                longitude: $0["longitude"]?.doubleValue ?? 0
            )
        }
    }

    private var displayCoords: [CLLocationCoordinate2D] {
        var upto = coords
        if !isLive, let i = scrubIndex, points.indices.contains(i) {
            upto = Array(upto.prefix(i + 1))
        }
        return downsample(upto, limit: 600)
    }

    private var scrubbedPoint: (CLLocationCoordinate2D, Date)? {
        guard let i = scrubIndex, points.indices.contains(i),
              let lat = points[i]["latitude"]?.doubleValue,
              let lon = points[i]["longitude"]?.doubleValue,
              let ts = points[i]["timestamp"]?.doubleValue else { return nil }
        return (CLLocationCoordinate2D(latitude: lat, longitude: lon), Date(timeIntervalSince1970: ts))
    }

    private var distText: String {
        let metric = (Locale.current.measurementSystem == .metric)
        let v = metric ? bridge.tripDistance / 1000 : bridge.tripDistance / 1609.34
        return String(format: v < 10 ? "%.2f %@" : "%.1f %@", v, metric ? "km" : "mi")
    }

    private var durationText: String {
        let t = Int(bridge.tripDuration)
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    private func timeLabel(_ i: Int?) -> String? {
        guard let i, points.indices.contains(i), let ts = points[i]["timestamp"]?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: ts).formatted(date: .omitted, time: .standard)
    }

    private func reloadPoints() {
        guard let gl = GLManager.shared(), bridge.tripInProgress,
              let arr = gl.currentTripPoints() as? [[String: NSNumber]] else {
            points = []
            return
        }
        points = arr
        if followingLive {
            scrubID = points.last?["id"]?.int64Value
        } else if scrubIndex == nil {
            scrubID = points.first?["id"]?.int64Value
            focusScrub()
        }
    }

    private func focusScrub() {
        guard let (coord, _) = scrubbedPoint else { return }
        camera = .region(MKCoordinateRegion(
            center: coord,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        ))
    }

    private func downsample(_ coords: [CLLocationCoordinate2D], limit: Int) -> [CLLocationCoordinate2D] {
        guard coords.count > limit, limit > 1 else { return coords }
        let stride = Double(coords.count - 1) / Double(limit - 1)
        return (0..<limit).map { coords[Int((Double($0) * stride).rounded())] }
    }
}
