import Foundation
import SQLite3
import CryptoKit

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct PendingEvent {
    public let eventUUID: String
    public let endpoint: String
    public let payloadJSON: String
    public let retryCount: Int
}

public enum DeliveryOutcome: Equatable { case delivered, retryLater, unauthorized }

public protocol EventTransport {
    func send(endpoint: String, jsonData: Data, bearerToken: String) async -> DeliveryOutcome
}

public struct URLSessionEventTransport: EventTransport {
    public let baseURL: String
    public let timeoutSec: TimeInterval
    public init(baseURL: String, timeoutSec: TimeInterval = 10) { self.baseURL = baseURL; self.timeoutSec = timeoutSec }
    public func send(endpoint: String, jsonData: Data, bearerToken: String) async -> DeliveryOutcome {
        guard let url = URL(string: baseURL + endpoint) else { return .retryLater }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.timeoutInterval = timeoutSec; req.httpBody = jsonData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .retryLater }
            return Self.outcome(forStatus: http.statusCode, endpoint: endpoint, responseData: data)
        } catch { return .retryLater }
    }
    public static func outcome(forStatus status: Int) -> DeliveryOutcome {
        switch status { case 200...299: return .delivered; case 401,403: return .unauthorized; default: return .retryLater }
    }
    public static func outcome(forStatus status: Int, endpoint: String, responseData: Data) -> DeliveryOutcome {
        let basic = outcome(forStatus: status)
        guard basic == .delivered, endpoint == "/api/v1/events/fall" else { return basic }
        guard let body = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any], let state = body["status"] as? String else { return .retryLater }
        if ["candidate_check_in_pending", "canceled_false_alarm", "suppressed_unworn_drop"].contains(state) { return .delivered }
        return state == "escalated_twilio" && (body["provider_accepted"] as? Bool == true || body["twilio_dispatched"] as? Bool == true) ? .delivered : .retryLater
    }
}

public enum QueueStorageError: Error, Equatable {
    case unavailable, invalidPayload, writeFailed(Int32), acknowledgmentFailed(Int32)
    public var message: String {
        "Some events could not be saved safely on this phone. Keep Cadence open and use the call buttons for help."
    }
}

/// Durable, account-and-destination-bound outbox. Legacy rows with no provable
/// owner remain quarantined. JWT claims are used ONLY as a local routing key;
/// the server still validates the signature/role on every request.
public final class EventSyncManager {
    public static let shared = EventSyncManager()
    private let dbQueue = DispatchQueue(label: "com.cadence.eventsync.db")
    private var db: OpaquePointer?
    private let path: String
    private var drainTask: Task<Void, Never>?
    private var isDraining = false
    private let autoDispatchEnabled: Bool
    private var currentURL = "http://localhost:8000"
    private var currentToken = "cadence-dev-device-writer-token-2026"
    private var currentOwner: String?
    private var lastOwnerByDestination: [String: String] = [:]
    private var currentTransport: EventTransport
    private var storageError: QueueStorageError?
    private struct Buffered {
        let event: PendingEvent
        let owner: String
        let destination: String
    }
    private var volatile: [String: Buffered] = [:]
    public var onUnauthorized: (() -> Void)?
    public var onPersistenceFailure: ((QueueStorageError) -> Void)?
    public var onPersistenceRecovered: (() -> Void)?
    public static let backoffScheduleSec: [Double] = [0, 5, 15, 60, 120, 300]

    public var persistenceError: QueueStorageError? { dbQueue.sync { storageError } }
    public var volatileEventCount: Int { dbQueue.sync { volatile.count } }
    public var backendBaseURL: String {
        get { dbQueue.sync { currentURL } }
        set { configureSession(baseURL: newValue, bearerToken: deviceBearerToken) }
    }
    public var deviceBearerToken: String {
        get { dbQueue.sync { currentToken } }
        set { configureSession(baseURL: backendBaseURL, bearerToken: newValue, replaceTransport: false) }
    }
    public var transport: EventTransport {
        get { dbQueue.sync { currentTransport } }
        set { dbQueue.sync { currentTransport = newValue } }
    }

    public init(transport: EventTransport? = nil, databasePath: String? = nil, startPeriodicDrain: Bool = true) {
        path = databasePath ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("cadence_local_queue.sqlite").path
        currentTransport = transport ?? URLSessionEventTransport(baseURL: "http://localhost:8000")
        autoDispatchEnabled = startPeriodicDrain
        openDatabase()
        currentOwner = Self.owner(for: currentToken)
        if startPeriodicDrain { startPeriodicDrainLoop() }
    }
    deinit { drainTask?.cancel(); if let db { sqlite3_close(db) } }

    /// Atomically replace credentials AND destination; in-flight requests retain
    /// their original session and a subsequent iteration stops after sign-out/switch.
    public func configureSession(baseURL: String, bearerToken: String, replaceTransport: Bool = true) {
        dbQueue.sync {
            var destination = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while destination.hasSuffix("/") { destination.removeLast() }
            currentURL = destination; currentToken = bearerToken
            currentOwner = Self.owner(for: bearerToken)
            if let owner = currentOwner {
                lastOwnerByDestination[destination] = owner
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO queue_identity(destination,owner_id) VALUES (?,?)", -1, &stmt, nil) == SQLITE_OK {
                    bind(stmt, 1, destination); bind(stmt, 2, owner); sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
            if replaceTransport { currentTransport = URLSessionEventTransport(baseURL: destination) }
        }
    }

    private static func owner(for token: String) -> String? {
        guard !token.isEmpty else { return nil }
        let parts = token.split(separator: ".")
        if parts.count == 3 {
            var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            if let data = Data(base64Encoded: encoded), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sub = claims["sub"] as? String, let pid = claims["pid"] as? String {
                let key = (try? JSONSerialization.data(withJSONObject: [sub,pid])) ?? Data()
                return SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
            }
        }
        // Opaque credentials are isolated by their hash, never stored in SQLite.
        return SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) { sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) }
    private func openDatabase() {
        if let db { sqlite3_close(db); self.db = nil }
        guard sqlite3_open(path, &db) == SQLITE_OK else { storageError = .unavailable; return }
        sqlite3_busy_timeout(db, 150)
        let schema = """
        PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS pending_events (
          event_uuid TEXT PRIMARY KEY, endpoint TEXT NOT NULL, payload_json TEXT NOT NULL,
          created_at_utc TEXT NOT NULL, retry_count INTEGER NOT NULL DEFAULT 0,
          synced INTEGER NOT NULL DEFAULT 0, next_attempt_at REAL NOT NULL DEFAULT 0,
          owner_id TEXT, destination TEXT
        );
        CREATE TABLE IF NOT EXISTS queue_identity(destination TEXT PRIMARY KEY,owner_id TEXT NOT NULL);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { storageError = .unavailable; return }
        // Columns are migrated BEFORE any index/query refers to them. Old rows
        // intentionally retain NULL ownership and are never adopted by a login.
        for column in ["next_attempt_at REAL NOT NULL DEFAULT 0", "owner_id TEXT", "destination TEXT"] {
            sqlite3_exec(db, "ALTER TABLE pending_events ADD COLUMN \(column)", nil, nil, nil)
        }
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_account_pending ON pending_events(owner_id,destination,synced,next_attempt_at)", nil, nil, nil)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT destination,owner_id FROM queue_identity", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let d = sqlite3_column_text(stmt,0), let o = sqlite3_column_text(stmt,1) { lastOwnerByDestination[String(cString:d)] = String(cString:o) }
            }
        }
        sqlite3_finalize(stmt)
        #if os(iOS)
        do { try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: path) }
        catch { storageError = .unavailable }
        #endif
    }

    @discardableResult
    public func saveLocalImmediate(eventUUID: String, endpoint: String, payload: [String: Any]) -> Result<Void, QueueStorageError> {
        guard JSONSerialization.isValidJSONObject(payload), let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data:data,encoding:.utf8) else {
            report(.invalidPayload); return .failure(.invalidPayload)
        }
        let result: Result<Void, QueueStorageError> = dbQueue.sync {
            let owner = currentOwner ?? lastOwnerByDestination[currentURL] ?? "unassigned"
            let item = Buffered(event: PendingEvent(eventUUID:eventUUID,endpoint:endpoint,payloadJSON:json,retryCount:0),owner:owner,destination:currentURL)
            let code = insert(item)
            guard code == SQLITE_DONE else {
                // Preserve original owner/destination even if another user signs in
                // while storage is unavailable. This is volatile, not a disk save.
                volatile[owner + "|" + currentURL + "|" + eventUUID] = item
                let error = QueueStorageError.writeFailed(code); storageError = error
                return .failure(error)
            }
            volatile.removeValue(forKey: owner + "|" + currentURL + "|" + eventUUID)
            return .success(())
        }
        if case let .failure(error) = result { onPersistenceFailure?(error) }
        if autoDispatchEnabled { Task { await self.drainPendingEvents() } }
        return result
    }
    private func report(_ error: QueueStorageError) { dbQueue.sync { storageError = error }; onPersistenceFailure?(error) }
    private func insert(_ item: Buffered) -> Int32 {
        var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
        let sql = """
        INSERT INTO pending_events(event_uuid,endpoint,payload_json,created_at_utc,owner_id,destination)
        VALUES(?,?,?,?,?,?) ON CONFLICT(event_uuid) DO UPDATE SET endpoint=excluded.endpoint,
          payload_json=excluded.payload_json,retry_count=0,synced=0,next_attempt_at=0
        WHERE pending_events.owner_id=excluded.owner_id AND pending_events.destination=excluded.destination;
        """
        let prepared = sqlite3_prepare_v2(db,sql,-1,&stmt,nil)
        guard prepared == SQLITE_OK else { return prepared }
        for (i,v) in [item.event.eventUUID,item.event.endpoint,item.event.payloadJSON,ISO8601DateFormatter().string(from:Date()),item.owner,item.destination].enumerated() { bind(stmt,Int32(i+1),v) }
        let code = sqlite3_step(stmt)
        return code == SQLITE_DONE && sqlite3_changes(db) == 0 ? SQLITE_CONSTRAINT : code
    }
    public func retryPersistingBufferedEvents() {
        let recovered = dbQueue.sync { () -> Bool in
            guard storageError != nil || !volatile.isEmpty else { return false }
            openDatabase()
            for (id,item) in volatile where insert(item) == SQLITE_DONE { volatile.removeValue(forKey:id) }
            if volatile.isEmpty, sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE {
                storageError = nil; return true
            }
            return false
        }
        if recovered { onPersistenceRecovered?() }
    }
    public func peekNext(now: Date = Date()) -> PendingEvent? { dueEvents(now:now).first }
    public func dueEvents(now: Date = Date()) -> [PendingEvent] { dbQueue.sync { due(now:now) } }
    private func due(now: Date) -> [PendingEvent] {
        guard let owner = currentOwner, !currentToken.isEmpty else { return [] }
        var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }; var rows:[PendingEvent] = []
        let sql = "SELECT event_uuid,endpoint,payload_json,retry_count FROM pending_events WHERE synced=0 AND next_attempt_at<=? AND owner_id=? AND destination=? ORDER BY CASE WHEN endpoint LIKE '/api/v1/events/fall%' THEN 0 ELSE 1 END,created_at_utc LIMIT 50"
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(stmt,1,now.timeIntervalSince1970); bind(stmt,2,owner); bind(stmt,3,currentURL)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let u=sqlite3_column_text(stmt,0),let e=sqlite3_column_text(stmt,1),let p=sqlite3_column_text(stmt,2) else { continue }
            rows.append(PendingEvent(eventUUID:String(cString:u),endpoint:String(cString:e),payloadJSON:String(cString:p),retryCount:Int(sqlite3_column_int(stmt,3))))
        }
        return rows
    }
    public func pendingCount() -> Int { count("synced=0") }
    public func quarantinedCount() -> Int { count("synced=0 AND (owner_id IS NULL OR owner_id='unassigned')") }
    private func count(_ predicate: String) -> Int {
        dbQueue.sync {
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db,"SELECT COUNT(*) FROM pending_events WHERE \(predicate)",-1,&stmt,nil)==SQLITE_OK,sqlite3_step(stmt)==SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt,0))
        }
    }
    public func retryCount(forEventUUID uuid: String) -> Int {
        dbQueue.sync {
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db,"SELECT retry_count FROM pending_events WHERE event_uuid=? AND owner_id=? AND destination=?",-1,&stmt,nil)==SQLITE_OK else { return 0 }
            bind(stmt,1,uuid);bind(stmt,2,currentOwner ?? "");bind(stmt,3,currentURL)
            return sqlite3_step(stmt)==SQLITE_ROW ? Int(sqlite3_column_int(stmt,0)) : 0
        }
    }
    @discardableResult
    public func drainPendingEvents(now: Date = Date()) async -> (delivered:Int,failed:Int) {
        retryPersistingBufferedEvents()
        let session = dbQueue.sync { () -> (String,String,String,EventTransport)? in
            guard !isDraining,let owner=currentOwner,!currentToken.isEmpty else { return nil }
            isDraining=true; return (owner,currentURL,currentToken,currentTransport)
        }
        guard let (owner,destination,token,transport)=session else { return (0,0) }
        defer { dbQueue.sync { isDraining=false } }
        var delivered=0;var failed=0
        for event in dueEvents(now:now) {
            guard dbQueue.sync(execute:{ currentOwner==owner && currentURL==destination && !currentToken.isEmpty }) else { break }
            let result=await transport.send(endpoint:event.endpoint,jsonData:Data(event.payloadJSON.utf8),bearerToken:token)
            let code = dbQueue.sync { () -> Int32 in
                var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
                let sql = result == .delivered ? "UPDATE pending_events SET synced=1 WHERE event_uuid=? AND owner_id=? AND destination=? AND payload_json=?" : "UPDATE pending_events SET retry_count=retry_count+1,next_attempt_at=? WHERE event_uuid=? AND owner_id=? AND destination=? AND payload_json=?"
                let prepared=sqlite3_prepare_v2(db,sql,-1,&stmt,nil);guard prepared==SQLITE_OK else { return prepared }
                var i:Int32=1
                if result != .delivered {
                    let delay=Self.backoffScheduleSec[min(event.retryCount+1,Self.backoffScheduleSec.count-1)]
                    sqlite3_bind_double(stmt,i,now.timeIntervalSince1970+delay);i+=1
                }
                for v in [event.eventUUID,owner,destination,event.payloadJSON] { bind(stmt,i,v);i+=1 }
                return sqlite3_step(stmt)
            }
            if code != SQLITE_DONE { report(.acknowledgmentFailed(code)); failed+=1 }
            else if result == .delivered { delivered+=1 } else { failed+=1 }
            if result == .unauthorized {
                if dbQueue.sync(execute: { currentOwner == owner && currentURL == destination && currentToken == token }) { onUnauthorized?() }
                break
            }
        }
        return (delivered,failed)
    }
    @discardableResult
    public func withdrawPending(_ uuid:String) -> Bool {
        dbQueue.sync {
            var stmt:OpaquePointer?;defer{sqlite3_finalize(stmt)}
            guard sqlite3_prepare_v2(db,"DELETE FROM pending_events WHERE event_uuid=? AND synced=0 AND owner_id=? AND destination=?",-1,&stmt,nil)==SQLITE_OK else { return false }
            bind(stmt,1,uuid);bind(stmt,2,currentOwner ?? "");bind(stmt,3,currentURL)
            return sqlite3_step(stmt)==SQLITE_DONE && sqlite3_changes(db)>0
        }
    }
    private func startPeriodicDrainLoop() {
        drainTask=Task{[weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds:15_000_000_000)
                guard !Task.isCancelled,let self else{return}
                await self.drainPendingEvents()
            }
        }
    }
}
