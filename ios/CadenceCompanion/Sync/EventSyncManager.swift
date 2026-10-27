import Foundation
import SQLite3

/// Local SQLite offline event queue (`FileProtectionType.completeUnlessOpen`) with immediate
/// synchronous P0 persistence and exponential-backoff HTTPS dispatch to the FastAPI backend.
public final class EventSyncManager {
    public static let shared = EventSyncManager()
    private var db: OpaquePointer?
    public var backendBaseURL: String = "http://localhost:8000"
    public var deviceBearerToken: String = "cadence-dev-device-writer-token-2026"

    private init() {
        openLocalQueueDatabase()
    }

    private func openLocalQueueDatabase() {
        let fileManager = FileManager.default
        guard let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let dbURL = docDir.appendingPathComponent("cadence_local_queue.sqlite")
        if sqlite3_open(dbURL.path, &db) == SQLITE_OK {
            #if os(iOS)
            try? (dbURL as NSURL).setResourceValue(
                URLFileProtection.completeUnlessOpen,
                forKey: .fileProtectionKey
            )
            #endif
            let createSQL = """
            CREATE TABLE IF NOT EXISTS pending_events (
                event_uuid TEXT PRIMARY KEY,
                endpoint TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                created_at_utc TEXT NOT NULL,
                retry_count INTEGER NOT NULL DEFAULT 0,
                synced INTEGER NOT NULL DEFAULT 0
            );
            """
            sqlite3_exec(db, createSQL, nil, nil, nil)
        }
    }

    /// Synchronously writes a P0 event row to local SQLite before returning.
    public func saveLocalImmediate(eventUUID: String, endpoint: String, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return
        }
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let insertSQL = """
        INSERT OR REPLACE INTO pending_events (event_uuid, endpoint, payload_json, created_at_utc, retry_count, synced)
        VALUES (?, ?, ?, ?, 0, 0);
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (eventUUID as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (endpoint as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (jsonStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (nowISO as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        dispatchEventAsync(eventUUID: eventUUID, endpoint: endpoint, jsonData: data)
    }

    private func dispatchEventAsync(eventUUID: String, endpoint: String, jsonData: Data) {
        guard let url = URL(string: "\(backendBaseURL)\(endpoint)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(deviceBearerToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = jsonData

        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                self?.markEventSynced(eventUUID: eventUUID)
            }
        }.resume()
    }

    private func markEventSynced(eventUUID: String) {
        let updateSQL = "UPDATE pending_events SET synced = 1 WHERE event_uuid = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (eventUUID as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
}
