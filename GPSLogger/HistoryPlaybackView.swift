import SwiftUI
import MapKit

struct ReplayCoordinate: Equatable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func interpolated(to other: ReplayCoordinate, fraction: Double) -> ReplayCoordinate {
        let start = MKMapPoint(coordinate)
        let end = MKMapPoint(other.coordinate)
        let worldWidth = MKMapRect.world.size.width
        var deltaX = end.x - start.x
        if deltaX > worldWidth / 2 { deltaX -= worldWidth }
        if deltaX < -worldWidth / 2 { deltaX += worldWidth }
        var x = start.x + deltaX * fraction
        if x < 0 { x += worldWidth }
        if x >= worldWidth { x -= worldWidth }
        return ReplayCoordinate(MKMapPoint(x: x, y: start.y + (end.y - start.y) * fraction).coordinate)
    }
}

@Observable
@MainActor
final class HistoryPlaybackModel {
    private(set) var points: [RecordedLocation] = []
    private(set) var selectedIndex: Int?
    private(set) var payload: RecordedPayload?
    private(set) var isPlaying = false
    private(set) var playbackTime: TimeInterval?
    private(set) var playbackCoordinate: ReplayCoordinate?
    private(set) var cameraCenter: ReplayCoordinate?
    private(set) var rulerTime: Date?
    var isBrowsing = false
    var playbackRate = 1

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastAdvance = 0.0
    @ObservationIgnored private var lastLoadedID: Int64 = 0
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var needsReload = false

    var selectedPoint: RecordedLocation? {
        guard let selectedIndex, points.indices.contains(selectedIndex) else { return nil }
        return points[selectedIndex]
    }

    var displayCoordinates: [CLLocationCoordinate2D] {
        guard isBrowsing, let selectedIndex else { return [] }
        let end = selectedIndex + 1
        let count = min(end, 599)
        var coordinates: [CLLocationCoordinate2D]
        if count == 1 {
            coordinates = [points[0].coordinate]
        } else {
            let stride = Double(end - 1) / Double(count - 1)
            coordinates = (0..<count).map { points[Int((Double($0) * stride).rounded())].coordinate }
        }
        if playbackTime != nil, let playbackCoordinate { coordinates.append(playbackCoordinate.coordinate) }
        return coordinates
    }

    var futureCoordinates: [CLLocationCoordinate2D] {
        guard isBrowsing, let selectedIndex else { return [] }
        let start = selectedIndex + 1
        guard start < points.count else { return [] }
        let count = min(points.count - start, 598)
        var coordinates = [playbackCoordinate?.coordinate ?? points[selectedIndex].coordinate]
        if count == 1 {
            coordinates.append(points[start].coordinate)
        } else {
            let stride = Double(points.count - start - 1) / Double(count - 1)
            coordinates += (0..<count).map { points[start + Int((Double($0) * stride).rounded())].coordinate }
        }
        return coordinates
    }

    var playbackIndex: Double {
        guard let selectedIndex else { return 0 }
        guard let playbackTime, points.indices.contains(selectedIndex + 1) else { return Double(selectedIndex) }
        let start = points[selectedIndex].timestamp.timeIntervalSince1970
        let end = points[selectedIndex + 1].timestamp.timeIntervalSince1970
        guard end > start else { return Double(selectedIndex) }
        return Double(selectedIndex) + min(1, max(0, (playbackTime - start) / (end - start)))
    }

    func reload() {
        if loading {
            needsReload = true
            return
        }
        loading = true
        RecentLocationHistory.shared.load(after: lastLoadedID) { [weak self] incoming in
            guard let self else { return }
            self.expireOldPoints()
            let selectedID = self.selectedPoint?.id
            self.lastLoadedID = max(self.lastLoadedID, incoming.last?.id ?? 0)
            self.points.append(contentsOf: incoming)
            self.points.sort {
                if $0.timestamp == $1.timestamp { return $0.id < $1.id }
                return $0.timestamp < $1.timestamp
            }
            if let selectedID {
                self.selectedIndex = self.points.firstIndex { $0.id == selectedID }
            }
            if self.isBrowsing && self.selectedIndex == nil && !self.points.isEmpty {
                self.selectNearest(to: self.rulerTime ?? self.points.last!.timestamp)
            }
            self.loading = false
            if self.needsReload {
                self.needsReload = false
                self.reload()
            }
        }
    }

    func expireOldPoints() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let selectedID = selectedPoint?.id
        let previousIndex = selectedIndex
        let previousCount = points.count
        points.removeAll { $0.timestamp < cutoff }
        guard points.count != previousCount else { return }
        if let playbackTime, let first = points.first,
           playbackTime < first.timestamp.timeIntervalSince1970 {
            pause()
            self.playbackTime = nil
        }
        if let selectedID, let previousIndex {
            if let matchingIndex = points.firstIndex(where: { $0.id == selectedID }) {
                self.selectedIndex = matchingIndex
            } else {
                self.selectedIndex = points.isEmpty ? nil : min(previousIndex, points.count - 1)
            }
            loadSelectedPayload()
        }
        if points.isEmpty {
            pause()
            playbackCoordinate = nil
            cameraCenter = nil
        } else if !isPlaying, let selectedPoint {
            let coordinate = ReplayCoordinate(selectedPoint.coordinate)
            playbackCoordinate = coordinate
            cameraCenter = coordinate
        }
    }

    func scrub(to time: Date) {
        let wasBrowsing = isBrowsing
        pause()
        isBrowsing = true
        rulerTime = time
        guard !points.isEmpty else {
            if !wasBrowsing { reload() }
            return
        }
        selectNearest(to: time)
    }

    func scrub(pointAt index: Int) {
        isBrowsing = true
        select(index)
    }

    func returnToLive() {
        pause()
        isBrowsing = false
        selectedIndex = nil
        payload = nil
        playbackTime = nil
        playbackCoordinate = nil
        cameraCenter = nil
        rulerTime = nil
    }

    func select(_ index: Int) {
        pause()
        playbackTime = nil
        setSelection(index)
        if let selectedPoint {
            rulerTime = selectedPoint.timestamp
            let coordinate = ReplayCoordinate(selectedPoint.coordinate)
            playbackCoordinate = coordinate
            cameraCenter = coordinate
        }
    }

    func step(_ direction: Int) {
        select((selectedIndex ?? points.count - 1) + direction)
    }

    func togglePlayback() {
        if isPlaying {
            pause()
            return
        }
        guard points.count > 1 else { return }
        isBrowsing = true
        if selectedIndex == nil || selectedIndex == points.count - 1 {
            playbackTime = nil
            setSelection(0)
            if let first = points.first {
                rulerTime = first.timestamp
                let coordinate = ReplayCoordinate(first.coordinate)
                playbackCoordinate = coordinate
                cameraCenter = coordinate
            }
        }
        guard let selectedPoint else { return }
        if playbackTime == nil { playbackTime = selectedPoint.timestamp.timeIntervalSince1970 }
        let coordinate = ReplayCoordinate(selectedPoint.coordinate)
        if playbackCoordinate == nil { playbackCoordinate = coordinate }
        if cameraCenter == nil { cameraCenter = coordinate }
        isPlaying = true
        lastAdvance = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
        timer?.tolerance = 0.004
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    private func advance() {
        guard isPlaying, let playbackTime, let last = points.last else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, now - lastAdvance)
        lastAdvance = now
        let end = last.timestamp.timeIntervalSince1970
        let current = min(end, playbackTime + elapsed * Double(playbackRate))
        self.playbackTime = current
        rulerTime = Date(timeIntervalSince1970: current)
        let index = index(at: current)
        setSelection(index)

        let start = ReplayCoordinate(points[index].coordinate)
        let target: ReplayCoordinate
        if points.indices.contains(index + 1) {
            let startTime = points[index].timestamp.timeIntervalSince1970
            let endTime = points[index + 1].timestamp.timeIntervalSince1970
            let fraction = endTime > startTime ? min(1, max(0, (current - startTime) / (endTime - startTime))) : 1
            target = start.interpolated(to: ReplayCoordinate(points[index + 1].coordinate), fraction: fraction)
        } else {
            target = start
        }
        playbackCoordinate = target
        if playbackRate >= 10 {
            cameraCenter = target
        } else {
            let follow = 1 - exp(-elapsed / 0.25)
            cameraCenter = cameraCenter?.interpolated(to: target, fraction: follow) ?? target
        }
        if current >= end {
            pause()
            cameraCenter = target
        }
    }

    private func index(at timestamp: TimeInterval) -> Int {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].timestamp.timeIntervalSince1970 <= timestamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(0, lower - 1)
    }

    private func selectNearest(to time: Date) {
        let previous = index(at: time.timeIntervalSince1970)
        let next = min(previous + 1, points.count - 1)
        let previousDistance = abs(points[previous].timestamp.timeIntervalSince(time))
        let nextDistance = abs(points[next].timestamp.timeIntervalSince(time))
        setSelection(nextDistance < previousDistance ? next : previous)
        if let selectedPoint {
            let coordinate = ReplayCoordinate(selectedPoint.coordinate)
            playbackCoordinate = coordinate
            cameraCenter = coordinate
        }
    }

    private func setSelection(_ index: Int) {
        guard !points.isEmpty else { return }
        let clamped = min(points.count - 1, max(0, index))
        guard selectedIndex != clamped else { return }
        selectedIndex = clamped
        loadSelectedPayload()
    }

    private func loadSelectedPayload() {
        guard let id = selectedPoint?.id else {
            payload = nil
            return
        }
        payload = nil
        RecentLocationHistory.shared.loadPayload(id: id) { [weak self] value in
            guard self?.selectedPoint?.id == id else { return }
            self?.payload = value
        }
    }
}

struct HistoryPlaybackView: View {
    var history: HistoryPlaybackModel
    @State private var showingRecord = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if history.points.isEmpty {
                ContentUnavailableView("No recent locations", systemImage: "location.slash",
                                       description: Text("Locations saved in the last 24 hours appear here."))
                    .frame(maxWidth: .infinity)
            } else {
                playbackControls
                pointDetails
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .sheet(isPresented: $showingRecord) { recordSheet }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3.weight(.medium))
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Route replay").font(.headline)
                Text((history.rulerTime ?? history.selectedPoint?.timestamp ?? Date())
                    .formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 10) {
            Button { history.step(-1) } label: {
                Image(systemName: "backward.end.fill")
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .glassButtonStyle()
            .disabled((history.selectedIndex ?? 0) == 0)
            .accessibilityLabel("Previous point")

            Button { history.togglePlayback() } label: {
                Label(history.isPlaying ? "Pause" : "Play",
                      systemImage: history.isPlaying ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .glassButtonStyle(prominent: true, tint: .blue)

            Button { history.step(1) } label: {
                Image(systemName: "forward.end.fill")
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .glassButtonStyle()
            .disabled((history.selectedIndex ?? 0) >= history.points.count - 1)
            .accessibilityLabel("Next point")

            Menu {
                ForEach([1, 5, 10, 20, 50], id: \.self) { rate in
                    Button("\(rate)× recorded time") {
                        history.playbackRate = rate
                    }
                }
            } label: {
                Text("\(history.playbackRate)×")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 46, minHeight: 38)
            }
            .glassButtonStyle()
            .accessibilityLabel("Playback speed")
        }
        .disabled(history.points.count < 2)
    }

    private var pointDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(history.playbackIndex > Double(history.selectedIndex ?? 0) + 0.001
                     ? "Last logged point \((history.selectedIndex ?? 0) + 1)"
                     : "Point \((history.selectedIndex ?? 0) + 1)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(history.selectedPoint?.timestamp.formatted(date: .abbreviated, time: .standard) ?? "")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let point = history.selectedPoint {
                detail("Location", value: String(format: "%.7f, %.7f", point.latitude, point.longitude),
                       symbol: "location.fill")
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) { metricDetails }
                } else {
                    HStack(spacing: 16) { metricDetails }
                }
                detail("Device", value: history.payload?.device ?? "Not in record", symbol: "iphone")
                Button {
                    showingRecord = true
                } label: {
                    HStack {
                        Label("View upload record", systemImage: "curlybraces")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(history.payload == nil)
            }
        }
    }

    @ViewBuilder
    private var metricDetails: some View {
        detail("Accuracy", value: history.payload?.accuracy.map { String(format: "±%.0f m", $0) } ?? "—",
               symbol: "scope")
        detail("Speed", value: history.payload?.speed.map { String(format: "%.2f m/s", $0) } ?? "—",
               symbol: "speedometer")
        detail("Altitude", value: history.payload?.altitude.map { String(format: "%.1f m", $0) } ?? "—",
               symbol: "mountain.2")
        detail("Battery", value: history.payload?.battery ?? "—", symbol: "battery.100")
    }

    private func detail(_ title: String, value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.monospacedDigit())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("This is the record prepared for the upload queue. Delivery may still be pending.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(history.payload?.json ?? "")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle(history.payload?.format ?? "Upload record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingRecord = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct HistoryRuler: View {
    var history: HistoryPlaybackModel
    var onLive: () -> Void

    @State private var liveEdge = Date()
    @State private var dragOrigin: Double?
    @State private var dragPosition: Double?
    @State private var lastDraggedTick: Int?

    private let day: TimeInterval = 24 * 60 * 60
    private let tickSpacing: CGFloat = 12

    private var tickCount: Int {
        history.points.isEmpty ? 48 : history.points.count
    }

    private var position: Double {
        if let dragPosition { return dragPosition }
        guard history.isBrowsing else { return 0 }
        if history.points.isEmpty {
            guard let time = history.rulerTime else { return 0 }
            return min(48, max(0, liveEdge.timeIntervalSince(time) / day * 48))
        }
        return Double(history.points.count) - history.playbackIndex
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    tickMarks(position: position)
                    Capsule()
                        .fill(.blue)
                        .frame(width: 4, height: 26)
                        .shadow(color: .blue.opacity(0.35), radius: 3)
                        .position(x: geometry.size.width / 2, y: 13)
                }
                .frame(height: 28)

                Text(history.isBrowsing
                     ? (history.rulerTime ?? Date()).formatted(date: .abbreviated, time: .shortened)
                     : "LIVE")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(history.isBrowsing ? Color.primary : Color.blue)
                .frame(height: 18)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        if dragOrigin == nil {
                            liveEdge = Date()
                            dragOrigin = position
                            lastDraggedTick = nil
                        }
                        let movement = Double(value.translation.width / tickSpacing)
                        let target = clamped((dragOrigin ?? 0) + movement)
                        dragPosition = target
                        select(tick: Int(target.rounded()))
                    }
                    .onEnded { value in
                        guard let dragOrigin else { return }
                        let momentum = min(180, max(-180,
                            value.predictedEndTranslation.width - value.translation.width))
                        let movement = Double((value.translation.width + momentum) / tickSpacing)
                        let target = clamped(dragOrigin + movement)
                        select(tick: Int(target.rounded()))
                        self.dragOrigin = nil
                        lastDraggedTick = nil
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                            dragPosition = nil
                        }
                    }
            )
        }
        .frame(height: 46)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Location history ruler")
        .accessibilityValue(history.isBrowsing
                            ? (history.rulerTime ?? Date()).formatted(date: .abbreviated, time: .shortened)
                            : "Live")
        .accessibilityHint("Older points are on the left. Drag right to browse them, or left toward Live.")
        .accessibilityAdjustableAction { direction in
            lastDraggedTick = nil
            switch direction {
            case .increment:
                select(tick: min(tickCount, Int(position.rounded()) + 1))
            case .decrement:
                select(tick: max(0, Int(position.rounded()) - 1))
            @unknown default:
                break
            }
        }
        .onAppear { liveEdge = Date() }
    }

    private func tickMarks(position: Double) -> some View {
        Canvas { context, size in
            let center = size.width / 2
            let radius = Int(ceil(size.width / tickSpacing / 2)) + 1
            let first = max(0, Int(position) - radius)
            let last = min(tickCount, Int(position) + radius)
            guard first <= last else { return }
            for tick in first...last {
                let x = center + (CGFloat(position) - CGFloat(tick)) * tickSpacing
                let major = tick == 0 || tick.isMultiple(of: 5)
                var path = Path()
                path.move(to: CGPoint(x: x, y: major ? 4 : 9))
                path.addLine(to: CGPoint(x: x, y: 21))
                let color = Color.primary.opacity(major ? 0.5 : 0.25)
                context.stroke(path, with: .color(color), lineWidth: 1)
            }
        }
    }

    private func clamped(_ value: Double) -> Double {
        min(Double(tickCount), max(0, value))
    }

    private func select(tick: Int) {
        guard lastDraggedTick != tick else { return }
        lastDraggedTick = tick
        if tick == 0 {
            if history.isBrowsing { withAnimation(.easeInOut(duration: 0.35), onLive) }
            return
        }
        if history.points.isEmpty {
            let time = liveEdge.addingTimeInterval(-day * Double(tick) / 48)
            history.scrub(to: time)
        } else {
            let index = history.points.count - tick
            if history.isBrowsing { history.scrub(pointAt: index) }
            else { withAnimation(.easeInOut(duration: 0.35)) { history.scrub(pointAt: index) } }
        }
    }
}
