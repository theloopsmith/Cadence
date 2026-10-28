import Foundation
import SQLite3

#if canImport(Network)
import Network
#endif

/// SQLite needs to copy text passed to `sqlite3_bind_text`; the default
/// `nil` destructor tells it the buffer outlives the statement, which is not
/// true for a Swift temporary.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One queued event awaiting delivery to the backend.
public struct PendingEvent {
    public let eventUUID: String
    public let endpoint: String
    public let payloadJSON: String
    public let retryCount: Int
}

/// Abstracts the HTTPS POST so the retry policy can be tested without a network.
public protocol EventTransport {
    /// Delivers one event. Returns true when the backend accepted it (2xx).
    func send(endpoint: String, jsonData: Data, bearerToken: String) async -> Bool
}

/// Default transport: a plain URLSession POST against the FastAPI backend.
public struct URLSessionEventTransport: EventTransport {
    public let baseURL: String
    public let timeoutSec: TimeInterval

    public init(baseURL: String, timeoutSec: TimeInterval = 10.0) {
        self.baseURL = baseURL
        self.timeoutSec = timeoutSec
    }

    public func send(endpoint: String, jsonData: Data, bearerToken: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeoutSec
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = jsonData
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            // 4xx other than 429 means the backend rejected the payload itself;
            // replaying it will never succeed, so treat it as delivered and let
            // the row drain rather than retrying a poison event forever.
            if (200...299).contains(http.statusCode) { return true }
            if (400...499).contains(http.statusCode) && http.statusCode != 429 { return true }
            return false
        } catch {
            return false
        }
    }
}

/// Local SQLite offline event queue (`FileProtectionType.completeUnlessOpen`) with
/// immediate synchronous P0 persistence and backoff HTTPS dispatch to the FastAPI
/// backend.
///
/// The queue is the offline fail-safe for falls: a fall recorded with no network
/// must still reach the caregiver pipeline once connectivity returns. Rows are
/// therefore only marked `synced` on an accepted response, and the drain runs on
/// a timer as well as on each new save.
public final class EventSyncManager {
    public static let shared = EventSyncManager()

    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.cadence.eventsync.db")
    private var drainTask: Task<Void, Never>?

    public var backendBaseURL: String = "http://localhost:8000" {
        didSet { transport = URLSessionEventTransport(baseURL: backendBaseURL) }
    }
    public var deviceBearerToken: String = "cadence-dev-device-writer-token-2026"

    /// Swappable for tests.
    public var transport: EventTransport

    /// When false, the manager never dispatches on its own: neither the 15s
    /// periodic drain nor the opportunistic attempt on save. Tests drive
    /// `drainPendingEvents(now:)` explicitly so retry counts are deterministic.
    private let autoDispatchEnabled: Bool

    /// Backoff schedule in seconds, indexed by retry count and clamped at the end.
    /// Capped at 5 minutes so a fall queued overnight still retries regularly.
    public static let backoffScheduleSec: [Double] = [0, 5, 15, 60, 120, 300]

    public init(
        transport: EventTransport? = nil,
        databasePath: String? = nil,
        startPeriodicDrain: Bool = true
    ) {
        self.transport = transport ?? URLSessionEventTransport(baseURL: "http://localhost:8000")
        self.autoDispatchEnabled = startPeriodicDrain
        openLocalQueueDatabase(explicitPath: databasePath)
        if startPeriodicDrain {
            startPeriodicDrainLoop()
        }
    }

    deinit {
        drainTask?.cancel()
    }

    // MARK: - Storage

    private func openLocalQueueDatabase(explicitPath: String?) {
        var path = explicitPath
        if path == nil {
            let fm = FileManager.default
            guard let docDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return
            }
            let dbURL = docDir.appendingPathComponent("cadence_local_queue.sqlite")
            path = dbURL.path
            #if os(iOS)
            try? (dbURL as NSURL).setResourceValue(
                URLFileProtection.completeUnlessOpen,
                forKey: .fileProtectionKey
            )
            #endif
        }
        guard let dbPath = path, sqlite3_open(dbPath, &db) == SQLITE_OK else { return }

        let createSQL = """
        CREATE TABLE IF NOT EXISTS pending_events (
            event_uuid TEXT PRIMARY KEY,
            endpoint TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at_utc TEXT NOT NULL,
            retry_count INTEGER NOT NULL DEFAULT 0,
            synced INTEGER NOT NULL DEFAULT 0,
            next_attempt_at REAL NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_pending_unsynced
            ON pending_events(synced, next_attempt_at);
        """
        sqlite3_exec(db, createSQL, nil, nil, nil)
        // Pre-existing installs predate next_attempt_at; adding it is a no-op
        // when the column is already there.
        sqlite3_exec(
            db,
            "ALTER TABLE pending_events ADD COLUMN next_attempt_at REAL NOT NULL DEFAULT 0;",
            nil, nil, nil
        )
    }

    /// Synchronously writes a P0 event row to local SQLite before returning.
    public func saveLocalImmediate(eventUUID: String, endpoint: String, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return
        }
        let nowISO = ISO8601DateFormatter().string(from: Date())
        dbQueue.sync {
            let insertSQL = """
            INSERT OR REPLACE INTO pending_events
                (event_uuid, endpoint, payload_json, created_at_utc, retry_count, synced, next_attempt_at)
            VALUES (?, ?, ?, ?, 0, 0, 0);
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, eventUUID, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, endpoint, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, jsonStr, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, nowISO, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        // Attempt delivery right away; failures fall back to the backoff drain.
        if autoDispatchEnabled {
            Task { await self.drainPendingEvents() }
        }
    }

    /// Peeks at the next pending event without marking it synced.
    public func peekNext(now: Date = Date()) -> PendingEvent? {
        return dueEvents(now: now).first
    }

    /// Returns queued events whose backoff has elapsed, oldest first.
    public func dueEvents(now: Date = Date()) -> [PendingEvent] {
        dbQueue.sync {
            var out: [PendingEvent] = []
            let sql = """
            SELECT event_uuid, endpoint, payload_json, retry_count
            FROM pending_events
            WHERE synced = 0 AND next_attempt_at <= ?
            ORDER BY created_at_utc ASC
            LIMIT 50;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let u = sqlite3_column_text(stmt, 0),
                          let e = sqlite3_column_text(stmt, 1),
                          let p = sqlite3_column_text(stmt, 2) else { continue }
                    out.append(
                        PendingEvent(
                            eventUUID: String(cString: u),
                            endpoint: String(cString: e),
                            payloadJSON: String(cString: p),
                            retryCount: Int(sqlite3_column_int(stmt, 3))
                        )
                    )
                }
            }
            sqlite3_finalize(stmt)
            return out
        }
    }

    public func pendingCount() -> Int {
        dbQueue.sync {
            var count = 0
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(
                db, "SELECT COUNT(*) FROM pending_events WHERE synced = 0;", -1, &stmt, nil
            ) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
            return count
        }
    }

    public func retryCount(forEventUUID uuid: String) -> Int {
        dbQueue.sync {
            var n = 0
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(
                db, "SELECT retry_count FROM pending_events WHERE event_uuid = ?;", -1, &stmt, nil
            ) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    n = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
            return n
        }
    }

    // MARK: - Draining

    /// Delivers every due event once. Successes are marked synced; failures have
    /// their retry count incremented and their next attempt pushed out along the
    /// backoff schedule. Safe to call repeatedly.
    @discardableResult
    public func drainPendingEvents(now: Date = Date()) async -> (delivered: Int, failed: Int) {
        var delivered = 0
        var failed = 0

        for event in dueEvents(now: now) {
            guard let data = event.payloadJSON.data(using: .utf8) else {
                markSynced(event.eventUUID)   // unparseable row: do not retry forever
                continue
            }
            let ok = await transport.send(
                endpoint: event.endpoint,
                jsonData: data,
                bearerToken: deviceBearerToken
            )
            if ok {
                markSynced(event.eventUUID)
                delivered += 1
            } else {
                scheduleRetry(event.eventUUID, currentRetryCount: event.retryCount, now: now)
                failed += 1
            }
        }
        return (delivered, failed)
    }

    /// Removes an event that has not been delivered yet. Returns true if a
    /// pending row was withdrawn; false if it was already sent or unknown.
    @discardableResult
    public func withdrawPending(_ eventUUID: String) -> Bool {
        dbQueue.sync {
            var stmt: OpaquePointer?
            var removed = false
            if sqlite3_prepare_v2(
                db, "DELETE FROM pending_events WHERE event_uuid = ? AND synced = 0;", -1, &stmt, nil
            ) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, eventUUID, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_DONE {
                    removed = sqlite3_changes(db) > 0
                }
            }
            sqlite3_finalize(stmt)
            return removed
        }
    }

    private func markSynced(_ eventUUID: String) {
        dbQueue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(
                db, "UPDATE pending_events SET synced = 1 WHERE event_uuid = ?;", -1, &stmt, nil
            ) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, eventUUID, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    private func scheduleRetry(_ eventUUID: String, currentRetryCount: Int, now: Date) {
        let nextIndex = min(currentRetryCount + 1, Self.backoffScheduleSec.count - 1)
        let delay = Self.backoffScheduleSec[nextIndex]
        let nextAt = now.timeIntervalSince1970 + delay
        dbQueue.sync {
            var stmt: OpaquePointer?
            let sql = """
            UPDATE pending_events
            SET retry_count = retry_count + 1, next_attempt_at = ?
            WHERE event_uuid = ?;
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, nextAt)
                sqlite3_bind_text(stmt, 2, eventUUID, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    private func startPeriodicDrainLoop() {
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                guard let self else { return }
                await self.drainPendingEvents()
            }
        }
    }
}
