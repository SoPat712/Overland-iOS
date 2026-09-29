import Foundation
import MapKit
import SQLite3

struct RecordedLocation: Identifiable {
    let id: Int64
    let timestamp: Date
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct RecordedPayload {
    let format: String
    let speed: Double?
    let accuracy: Double?
    let altitude: Double?
    let device: String?
    let battery: String?
    let json: String
}

extension Notification.Name {
    static let recentLocationHistoryChanged = Notification.Name("RecentLocationHistoryChanged")
}

// A separate 24-hour copy of accepted upload records. Sending and queue deletion do not use it.
@objc(RecentLocationHistory)
final class RecentLocationHistory: NSObject {
    static let shared = RecentLocationHistory()

    private struct Entry {
        let timestamp: Double
        let latitude: Double
        let longitude: Double
        let format: Int32
        let payload: Data

        init?(_ update: NSDictionary) {
            guard let data = try? JSONSerialization.data(withJSONObject: update),
                  let value = update as? [String: Any] else { return nil }
            if let geometry = value["geometry"] as? [String: Any],
               let coords = geometry["coordinates"] as? [NSNumber], coords.count >= 2,
               let properties = value["properties"] as? [String: Any],
               let date = properties["timestamp"] as? String,
               let parsed = ISO8601DateFormatter().date(from: date) {
                timestamp = parsed.timeIntervalSince1970
                latitude = coords[1].doubleValue
                longitude = coords[0].doubleValue
                format = 0
            } else if let latitude = value["lat"] as? NSNumber,
                      let longitude = value["lon"] as? NSNumber,
                      let timestamp = value["tst"] as? NSNumber,
                      value["_type"] as? String == "location" {
                self.timestamp = timestamp.doubleValue
                self.latitude = latitude.doubleValue
                self.longitude = longitude.doubleValue
                format = 1
            } else {
                return nil
            }
            guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)),
                  timestamp.isFinite, timestamp > 0 else { return nil }
            payload = data
        }
    }

    private let queue = DispatchQueue(label: "com.overland.recent-location-history")
    private var database: OpaquePointer?
    private var lastPrune = 0.0
    private static let retention: TimeInterval = 24 * 60 * 60
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @objc(recordUpdate:)
    static func recordUpdate(_ update: NSDictionary) {
        guard let entry = Entry(update) else { return }
        shared.queue.async {
            guard shared.insert(entry) else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .recentLocationHistoryChanged, object: nil)
            }
        }
    }

    func load(after id: Int64, completion: @escaping ([RecordedLocation]) -> Void) {
        queue.async {
            let points = self.fetch(after: id)
            DispatchQueue.main.async { completion(points) }
        }
    }

    func loadPayload(id: Int64, completion: @escaping (RecordedPayload?) -> Void) {
        queue.async {
            let payload = self.fetchPayload(id: id)
            DispatchQueue.main.async { completion(payload) }
        }
    }

    private func open() -> OpaquePointer? {
        if let database { return database }
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("Recent Locations", isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: directory.path)
        } catch {
            NSLog("Recent location storage unavailable: %@", error.localizedDescription)
            return nil
        }
        let url = directory.appendingPathComponent("history.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 3000)
        // The incremental loader needs IDs to remain unique after all old rows expire.
        let table = """
        CREATE TABLE IF NOT EXISTS points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            format INTEGER NOT NULL,
            payload BLOB NOT NULL
        );
        """
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        \(table)
        CREATE INDEX IF NOT EXISTS points_timestamp ON points(timestamp);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            NSLog("Recent location schema failed: %s", sqlite3_errmsg(handle))
            sqlite3_close(handle)
            return nil
        }
        var autoincrement: Int32 = 0
        guard sqlite3_table_column_metadata(handle, nil, "points", "id", nil, nil,
                                            nil, nil, &autoincrement) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        if autoincrement == 0 {
            let migration = """
            BEGIN IMMEDIATE;
            ALTER TABLE points RENAME TO legacy_points;
            \(table)
            INSERT INTO points SELECT * FROM legacy_points;
            DROP TABLE legacy_points;
            CREATE INDEX points_timestamp ON points(timestamp);
            COMMIT;
            """
            guard sqlite3_exec(handle, migration, nil, nil, nil) == SQLITE_OK else {
                NSLog("Recent location migration failed: %s", sqlite3_errmsg(handle))
                sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
                sqlite3_close(handle)
                return nil
            }
        }
        database = handle
        return handle
    }

    private func insert(_ entry: Entry) -> Bool {
        guard let database = open() else { return false }
        let sql = "INSERT INTO points (timestamp, latitude, longitude, format, payload) VALUES (?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        let payloadStatus = entry.payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 5, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
        guard sqlite3_bind_double(statement, 1, entry.timestamp) == SQLITE_OK,
              sqlite3_bind_double(statement, 2, entry.latitude) == SQLITE_OK,
              sqlite3_bind_double(statement, 3, entry.longitude) == SQLITE_OK,
              sqlite3_bind_int(statement, 4, entry.format) == SQLITE_OK,
              payloadStatus == SQLITE_OK else {
            NSLog("Recent location bind failed: %s", sqlite3_errmsg(database))
            return false
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            NSLog("Recent location insert failed: %s", sqlite3_errmsg(database))
            return false
        }
        let now = Date().timeIntervalSince1970
        if now - lastPrune > 3600 {
            prune(database, before: now - Self.retention)
            lastPrune = now
        }
        return true
    }

    private func prune(_ database: OpaquePointer, before cutoff: Double) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM points WHERE timestamp < ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        sqlite3_step(statement)
    }

    private func fetch(after id: Int64) -> [RecordedLocation] {
        guard let database = open() else { return [] }
        let cutoff = Date().timeIntervalSince1970 - Self.retention
        prune(database, before: cutoff)
        let sql = "SELECT id, timestamp, latitude, longitude FROM points WHERE id > ? AND timestamp >= ? ORDER BY id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        sqlite3_bind_double(statement, 2, cutoff)
        var points: [RecordedLocation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            points.append(RecordedLocation(
                id: sqlite3_column_int64(statement, 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                latitude: sqlite3_column_double(statement, 2),
                longitude: sqlite3_column_double(statement, 3)
            ))
        }
        return points
    }

    private func fetchPayload(id: Int64) -> RecordedPayload? {
        guard let database = open() else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT format, payload FROM points WHERE id = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let blob = sqlite3_column_blob(statement, 1) else { return nil }
        let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1)))
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pretty = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: pretty, encoding: .utf8) else { return nil }
        if sqlite3_column_int(statement, 0) == 1 {
            let battery = (value["batt"] as? NSNumber)?.intValue
            return RecordedPayload(
                format: "OwnTracks",
                speed: nil,
                accuracy: Self.nonnegative(value["acc"]),
                altitude: nil,
                device: (value["topic"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                battery: battery.flatMap { $0 >= 0 ? "\($0)%" : nil },
                json: json
            )
        }
        let properties = value["properties"] as? [String: Any] ?? [:]
        let battery = Self.nonnegative(properties["battery_level"])
        return RecordedPayload(
            format: "GeoJSON",
            speed: Self.nonnegative(properties["speed"]),
            accuracy: Self.nonnegative(properties["horizontal_accuracy"]),
            altitude: (properties["altitude"] as? NSNumber)?.doubleValue,
            device: (properties["device_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            battery: battery.map { "\(Int(($0 * 100).rounded()))%" },
            json: json
        )
    }

    private static func nonnegative(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    deinit {
        if let database { sqlite3_close(database) }
    }
}
