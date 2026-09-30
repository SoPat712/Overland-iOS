import SwiftUI
import MapKit

enum SettingsDestination: Hashable {
    case server
    case wifiZones
    case trip
}

struct OverlandRootView: View {
    @State private var selection = 0
    @State private var mapTab = 0
    @State private var settingsPath: [SettingsDestination] = []
    @State private var mapAppearance = MapAppearance.standard
    @State private var camera = MapCameraPosition.userLocation(fallback: .automatic)
    @State private var trip = TripMapState()
    @State private var history = HistoryPlaybackModel()
    @State private var bridge = GLManagerBridge.shared
    @State private var liveCameraTask: Task<Void, Never>?
    @State private var panelTop: CGFloat?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum MapAppearance: String, CaseIterable {
        case standard = "Map"
        case hybrid = "Hybrid"
        case imagery = "Satellite"

        var style: MapStyle {
            switch self {
            case .standard: return .standard
            case .hybrid: return .hybrid
            case .imagery: return .imagery
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let initialClearance = dynamicTypeSize.isAccessibilitySize
                ? min(560, geometry.size.height * 0.64)
                : min(483, geometry.size.height * 0.55)
            // MapKit positions its own credit from the map's safe area.
            let creditClearance = panelTop.map { max(0, geometry.size.height - $0 + 9) }
                ?? initialClearance
            OverlandNativeTabs(
                selection: $selection,
                panelTop: $panelTop,
                map: AnyView(mapPage(reserving: creditClearance)),
                controls: AnyView(panelContent),
                settings: AnyView(settingsPage),
                onSelect: selectTab
            )
            .ignoresSafeArea(.container)
        }
        .onChange(of: camera.followsUserLocation) { _, follows in
            if follows {
                trip.followingLive = true
                trip.scrubID = trip.points.last?["id"]?.int64Value
                history.returnToLive()
            }
        }
        .onChange(of: history.cameraCenter) { previous, center in
            focusHistoryPosition(center, from: previous)
        }
        .onChange(of: bridge.tripInProgress) { _, _ in
            trip = TripMapState()
            reloadTripPoints()
        }
        .onChange(of: bridge.tick) { _, tick in
            reloadTripPoints()
            if tick % 60 == 0 { history.expireOldPoints() }
        }
        .onChange(of: selection) { _, _ in reloadTripPoints() }
        .onReceive(NotificationCenter.default.publisher(for: .recentLocationHistoryChanged)) { _ in
            history.reload()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { history.reload() }
            else { history.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OverlandOpenTracker"))) { _ in
            selection = 0
            selectTab(0)
        }
        .onAppear { history.reload() }
        .tint(.blue)
    }

    private func mapPage(reserving bottomClearance: CGFloat) -> some View {
        map
            .safeAreaInset(edge: .bottom, spacing: 8) {
                Color.clear.frame(height: bottomClearance)
            }
            .overlay(alignment: .topLeading) {
                if mapTab == 0 {
                    TrackerSpeedometer(replaySpeed: history.payload?.speed, isReplaying: history.isBrowsing)
                        .padding(.leading, 14)
                        .padding(.top, 6)
                }
            }
            .overlay(alignment: .topTrailing) {
                mapControls
                    .padding(.trailing, 14)
                    .padding(.top, 6)
            }
    }

    @ViewBuilder
    private var panelContent: some View {
        if mapTab == 0 {
            TrackerView(history: history, onLive: returnToLive)
        } else {
            TripView(camera: $camera, trip: $trip)
        }
    }

    private var settingsPage: some View {
        NavigationStack(path: $settingsPath) {
            SettingsView()
                .navigationDestination(for: SettingsDestination.self) { destination in
                    switch destination {
                    case .server:
                        EndpointView()
                    case .wifiZones:
                        WifiZoneListView()
                    case .trip:
                        TripSettingsView()
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar(.visible, for: .navigationBar)
                    }
                }
        }
    }

    private func reloadTripPoints() {
        guard selection == 1 else { return }
        guard let gl = GLManager.shared(), bridge.tripInProgress,
              let points = gl.currentTripPoints() as? [[String: NSNumber]] else {
            trip = TripMapState()
            return
        }
        trip.points = points
        if trip.followingLive {
            trip.scrubID = points.last?["id"]?.int64Value
        } else if trip.scrubIndex == nil {
            trip.scrubID = points.first?["id"]?.int64Value
            if let coordinate = trip.scrubbedCoordinate {
                camera = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                ))
            }
        }
    }

    private var map: some View {
        let coords = mapTab == 1 ? trip.displayCoords : history.displayCoordinates
        let future = mapTab == 0 ? history.futureCoordinates : []
        return Map(position: $camera) {
            UserAnnotation { CurrentLocationMarker() }
            if future.count > 1 {
                MapPolyline(coordinates: future)
                    .stroke(.teal.opacity(0.65),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round,
                                               lineJoin: .round, dash: [7, 6]))
            }
            if coords.count > 1 {
                MapPolyline(coordinates: coords)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if mapTab == 1, !trip.followingLive, let coordinate = trip.scrubbedCoordinate {
                Marker("Trip point", systemImage: "mappin.circle.fill", coordinate: coordinate)
                    .tint(.blue)
            }
            if mapTab == 0, history.isBrowsing,
               let coordinate = history.playbackCoordinate?.coordinate ?? history.selectedPoint?.coordinate {
                Marker("Recorded point", systemImage: "mappin.circle.fill", coordinate: coordinate)
                    .tint(.blue)
            }
        }
        .mapStyle(mapAppearance.style)
        .mapControls { }
    }

    private var mapControls: some View {
        VStack(spacing: 0) {
            Menu {
                Picker("Map style", selection: $mapAppearance) {
                    ForEach(MapAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.rawValue).tag(appearance)
                    }
                }
            } label: {
                Image(systemName: "map.fill")
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Map style")
            Button {
                trip.followingLive = true
                trip.scrubID = trip.points.last?["id"]?.int64Value
                returnToLive()
            } label: {
                Image(systemName: camera.followsUserLocation ? "location.fill" : "location")
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Show My Location")
            if mapTab == 1 {
                Button {
                    settingsPath = [.trip]
                    selection = 2
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Trip Settings")
            }
        }
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .frame(width: 52)
        .glassTabBarBackground()
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private func selectTab(_ index: Int) {
        if index == 2 { settingsPath = [] }
        if index != 0 { history.pause() }
        selection = index
        if index < 2 { mapTab = index }
        if index == 0 { focusHistoryPosition(history.cameraCenter) }
    }

    private func focusHistoryPosition(_ position: ReplayCoordinate?, from previous: ReplayCoordinate? = nil) {
        guard selection == 0, history.isBrowsing, let coordinate = position?.coordinate else { return }
        liveCameraTask?.cancel()
        let span = history.isPlaying ? 0.005 * sqrt(Double(history.playbackRate)) : 0.005
        let target = MapCameraPosition.region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
        ))
        let jumpDistance = previous.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        } ?? 0
        if history.isPlaying || jumpDistance > 1_000 || UIAccessibility.isReduceMotionEnabled {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { camera = target }
        } else {
            let duration = camera.followsUserLocation ? 0.65 : 0.32
            withAnimation(.easeInOut(duration: duration)) { camera = target }
        }
    }

    private func returnToLive() {
        liveCameraTask?.cancel()
        withAnimation(.easeInOut(duration: 0.35)) { history.returnToLive() }
        guard selection == 0, let location = GLManager.shared()?.lastLocation,
              !UIAccessibility.isReduceMotionEnabled else {
            camera = .userLocation(fallback: .automatic)
            return
        }

        withAnimation(.easeInOut(duration: 0.65)) {
            camera = .region(MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            ))
        }
        liveCameraTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, !history.isBrowsing, selection == 0 else { return }
            camera = .userLocation(fallback: .automatic)
        }
    }

}

extension View {
    @ViewBuilder
    func glassTabBarBackground() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.background(Capsule().fill(.ultraThinMaterial))
        }
    }
}

final class OverlandRootHosting: NSObject {
    @objc static func makeRoot() -> UIViewController {
        UIHostingController(rootView: OverlandRootView())
    }
}
