import Foundation
import SQLite3
import CryptoKit

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct PendingEvent {
    public let eventUUID: String
    public let endpoint: String
    public let payloadJSON: String
    public let retryCount: Int
    public let dataGeneration: Int
    public init(eventUUID: String, endpoint: String, payloadJSON: String, retryCount: Int, dataGeneration: Int = 0) {
        self.eventUUID = eventUUID; self.endpoint = endpoint; self.payloadJSON = payloadJSON
        self.retryCount = retryCount; self.dataGeneration = dataGeneration
    }
}

public enum DeliveryOutcome: Equatable { case delivered, discarded, retryLater, unauthorized }

public protocol EventTransport {
    func send(endpoint: String, jsonData: Data, bearerToken: String) async -> DeliveryOutcome
}

public protocol DataGenerationTransport: EventTransport {
    func fetchDataGeneration(bearerToken: String) async throws -> Int
    func send(endpoint: String, jsonData: Data, bearerToken: String, dataGeneration: Int) async -> DeliveryOutcome
}

public struct URLSessionEventTransport: DataGenerationTransport {
    public let baseURL: String
    public let timeoutSec: TimeInterval
    public init(baseURL: String, timeoutSec: TimeInterval = 10) { self.baseURL = baseURL; self.timeoutSec = timeoutSec }
    public func send(endpoint: String, jsonData: Data, bearerToken: String) async -> DeliveryOutcome {
        await send(endpoint: endpoint, jsonData: jsonData, bearerToken: bearerToken, dataGeneration: 0)
    }
    public func fetchDataGeneration(bearerToken: String) async throws -> Int {
        let client = CadenceAPIClient(baseURL: baseURL, bearerToken: bearerToken, transport: URLSessionJSONTransport(timeoutSec: timeoutSec))
        // A server that predates the erase ledger reports no generation. That is
        // generation 0, not a reason to hold every fall event on the phone.
        return max(0, try await client.connectionInfo().dataGeneration ?? 0)
    }
    public func send(endpoint: String, jsonData: Data, bearerToken: String, dataGeneration: Int) async -> DeliveryOutcome {
        guard let url = URL(string: baseURL + endpoint) else { return .retryLater }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.timeoutInterval = timeoutSec; req.httpBody = jsonData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.setValue(String(dataGeneration), forHTTPHeaderField: "X-Cadence-Data-Generation")
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
        let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        if status == 409, json?["error"] as? String == "data_generation_changed", let generation = json?["data_generation"] as? Int, generation >= 0 { return .discarded }
        if (200...299).contains(status), json?["status"] as? String == "dropped_wiped" { return .discarded }
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
    public static let shared: EventSyncManager = {
        let queue = EventSyncManager(databasePath: DeviceProfile.shared.directory.appendingPathComponent("queue.sqlite").path,
            startPeriodicDrain: NSClassFromString("XCTestCase") == nil)
        queue.configureSession(baseURL: "", bearerToken: "")
        return queue
    }()
    private let dbQueue = DispatchQueue(label: "com.cadence.eventsync.db")
    private var db: OpaquePointer?
    private let path: String
    private var drainTask: Task<Void, Never>?
    private var isDraining = false
    private var suspended = false
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
    public var onServerDataErased: (() -> Void)?
    public static let backoffScheduleSec: [Double] = [0, 5, 15, 60, 120, 300]

    public var persistenceError: QueueStorageError? { dbQueue.sync { storageError } }
    public var volatileEventCount: Int { dbQueue.sync { volatile.count } }
    public var currentDataGeneration: Int {
        dbQueue.sync { generation(owner: currentOwner ?? lastOwnerByDestination[currentURL] ?? "unassigned", destination: currentURL) }
    }
    var isUploading: Bool { dbQueue.sync { isDraining } }
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
            guard !suspended else { return }
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

    static func owner(for token: String) -> String? {
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
    private func generation(owner: String, destination: String) -> Int {
        var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db,"SELECT data_generation FROM server_generations WHERE owner_id=? AND destination=?",-1,&stmt,nil) == SQLITE_OK else { return 0 }
        bind(stmt,1,owner); bind(stmt,2,destination)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt,0)) : 0
    }

    private func recordedGeneration(uuid: String, owner: String, destination: String) -> Int? {
        var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db,"SELECT data_generation FROM pending_events WHERE event_uuid=? AND owner_id=? AND destination=?",-1,&stmt,nil) == SQLITE_OK else { return nil }
        bind(stmt,1,uuid); bind(stmt,2,owner); bind(stmt,3,destination)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt,0)) : nil
    }

    /// Learning a wipe generation retires old rows without calling them delivered.
    /// It never assigns a new generation to an old action.
    @discardableResult
    public func observeDataGeneration(_ value: Int, bearerToken: String, baseURL: String) -> Bool {
        var changed = false
        let result: Result<Bool, QueueStorageError> = dbQueue.sync {
            guard value >= 0, !suspended, currentToken == bearerToken, !bearerToken.isEmpty,
                  currentURL == baseURL, let owner = currentOwner else { return .success(false) }
            let old = generation(owner: owner, destination: baseURL)
            guard value >= old else { return .success(false) }
            guard sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil) == SQLITE_OK else { return .failure(.unavailable) }
            var stmt: OpaquePointer?
            let prepared = sqlite3_prepare_v2(db,"INSERT INTO server_generations(owner_id,destination,data_generation) VALUES(?,?,?) ON CONFLICT(owner_id,destination) DO UPDATE SET data_generation=excluded.data_generation",-1,&stmt,nil)
            var code = prepared
            if prepared == SQLITE_OK {
                bind(stmt,1,owner); bind(stmt,2,baseURL); sqlite3_bind_int64(stmt,3,sqlite3_int64(value))
                code = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt); stmt = nil
            if code == SQLITE_DONE {
                code = sqlite3_prepare_v2(db,"UPDATE pending_events SET synced=2 WHERE synced=0 AND owner_id=? AND destination=? AND data_generation<?",-1,&stmt,nil)
                if code == SQLITE_OK {
                    bind(stmt,1,owner); bind(stmt,2,baseURL); sqlite3_bind_int64(stmt,3,sqlite3_int64(value)); code = sqlite3_step(stmt)
                }
            }
            sqlite3_finalize(stmt)
            guard code == SQLITE_DONE, sqlite3_exec(db,"COMMIT",nil,nil,nil) == SQLITE_OK else {
                sqlite3_exec(db,"ROLLBACK",nil,nil,nil); return .failure(.writeFailed(code))
            }
            for (key,item) in volatile where item.owner == owner && item.destination == baseURL && item.event.dataGeneration < value {
                volatile.removeValue(forKey: key)
            }
            changed = value > old
            return .success(true)
        }
        switch result {
        case .success(let accepted):
            if changed { onServerDataErased?() }
            return accepted
        case .failure(let error): report(error); return false
        }
    }
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
        CREATE TABLE IF NOT EXISTS server_generations(owner_id TEXT NOT NULL,destination TEXT NOT NULL,data_generation INTEGER NOT NULL,
          PRIMARY KEY(owner_id,destination));
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { storageError = .unavailable; return }
        // Columns are migrated BEFORE any index/query refers to them. Old rows
        // intentionally retain NULL ownership and are never adopted by a login.
        for column in ["next_attempt_at REAL NOT NULL DEFAULT 0", "owner_id TEXT", "destination TEXT", "data_generation INTEGER NOT NULL DEFAULT 0"] {
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
    public func saveLocalImmediate(eventUUID: String, endpoint: String, payload: [String: Any], dataGeneration: Int? = nil) -> Result<Void, QueueStorageError> {
        guard JSONSerialization.isValidJSONObject(payload), let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data:data,encoding:.utf8) else {
            report(.invalidPayload); return .failure(.invalidPayload)
        }
        let result: Result<Void, QueueStorageError> = dbQueue.sync {
            guard !suspended else { return .failure(.unavailable) }
            let owner = currentOwner ?? lastOwnerByDestination[currentURL] ?? "unassigned"
            let version = dataGeneration ?? recordedGeneration(uuid: eventUUID, owner: owner, destination: currentURL) ?? generation(owner: owner, destination: currentURL)
            let item = Buffered(event: PendingEvent(eventUUID:eventUUID,endpoint:endpoint,payloadJSON:json,retryCount:0,dataGeneration:version),owner:owner,destination:currentURL)
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
        INSERT INTO pending_events(event_uuid,endpoint,payload_json,created_at_utc,owner_id,destination,data_generation)
        VALUES(?,?,?,?,?,?,?) ON CONFLICT(event_uuid) DO UPDATE SET endpoint=excluded.endpoint,
          payload_json=excluded.payload_json,retry_count=0,synced=0,next_attempt_at=0
        WHERE pending_events.owner_id=excluded.owner_id AND pending_events.destination=excluded.destination
          AND pending_events.data_generation=excluded.data_generation;
        """
        let prepared = sqlite3_prepare_v2(db,sql,-1,&stmt,nil)
        guard prepared == SQLITE_OK else { return prepared }
        for (i,v) in [item.event.eventUUID,item.event.endpoint,item.event.payloadJSON,ISO8601DateFormatter().string(from:Date()),item.owner,item.destination].enumerated() { bind(stmt,Int32(i+1),v) }
        sqlite3_bind_int64(stmt,7,sqlite3_int64(item.event.dataGeneration))
        let code = sqlite3_step(stmt)
        return code == SQLITE_DONE && sqlite3_changes(db) == 0 ? SQLITE_CONSTRAINT : code
    }
    public func retryPersistingBufferedEvents() {
        let recovered = dbQueue.sync { () -> Bool in
            guard !suspended else { return false }
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
        let sql = "SELECT event_uuid,endpoint,payload_json,retry_count,data_generation FROM pending_events WHERE synced=0 AND next_attempt_at<=? AND owner_id=? AND destination=? ORDER BY CASE WHEN endpoint LIKE '/api/v1/events/fall%' THEN 0 ELSE 1 END,created_at_utc LIMIT 50"
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(stmt,1,now.timeIntervalSince1970); bind(stmt,2,owner); bind(stmt,3,currentURL)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let u=sqlite3_column_text(stmt,0),let e=sqlite3_column_text(stmt,1),let p=sqlite3_column_text(stmt,2) else { continue }
            rows.append(PendingEvent(eventUUID:String(cString:u),endpoint:String(cString:e),payloadJSON:String(cString:p),retryCount:Int(sqlite3_column_int(stmt,3)),dataGeneration:Int(sqlite3_column_int64(stmt,4))))
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
            guard !suspended, !isDraining,let owner=currentOwner,!currentToken.isEmpty else { return nil }
            isDraining=true; return (owner,currentURL,currentToken,currentTransport)
        }
        guard let (owner,destination,token,transport)=session else { return (0,0) }
        defer { dbQueue.sync { isDraining=false } }
        var delivered=0;var failed=0
        if let versioned = transport as? DataGenerationTransport {
            do {
                let value = try await versioned.fetchDataGeneration(bearerToken: token)
                guard observeDataGeneration(value, bearerToken: token, baseURL: destination) else { return (0,dueEvents(now: now).count) }
            } catch {
                if let apiError = error as? CadenceAPIError, case .httpStatus(let status) = apiError,
                   [401,403].contains(status), dbQueue.sync(execute: { currentToken == token && currentURL == destination }) { onUnauthorized?() }
                return (0,dueEvents(now: now).count)
            }
        }
        for event in dueEvents(now:now) {
            guard dbQueue.sync(execute:{ currentOwner==owner && currentURL==destination && !currentToken.isEmpty }) else { break }
            let result: DeliveryOutcome
            if let versioned = transport as? DataGenerationTransport {
                result = await versioned.send(endpoint:event.endpoint,jsonData:Data(event.payloadJSON.utf8),bearerToken:token,dataGeneration:event.dataGeneration)
            } else { result = await transport.send(endpoint:event.endpoint,jsonData:Data(event.payloadJSON.utf8),bearerToken:token) }
            let code = dbQueue.sync { () -> Int32 in
                var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
                let terminal = result == .delivered || result == .discarded
                let sql = terminal ? "UPDATE pending_events SET synced=\(result == .delivered ? 1 : 2) WHERE event_uuid=? AND owner_id=? AND destination=? AND payload_json=? AND data_generation=?" : "UPDATE pending_events SET retry_count=retry_count+1,next_attempt_at=? WHERE event_uuid=? AND owner_id=? AND destination=? AND payload_json=? AND data_generation=?"
                let prepared=sqlite3_prepare_v2(db,sql,-1,&stmt,nil);guard prepared==SQLITE_OK else { return prepared }
                var i:Int32=1
                if !terminal {
                    let delay=Self.backoffScheduleSec[min(event.retryCount+1,Self.backoffScheduleSec.count-1)]
                    sqlite3_bind_double(stmt,i,now.timeIntervalSince1970+delay);i+=1
                }
                for v in [event.eventUUID,owner,destination,event.payloadJSON] { bind(stmt,i,v);i+=1 }
                sqlite3_bind_int64(stmt,i,sqlite3_int64(event.dataGeneration))
                return sqlite3_step(stmt)
            }
            if code != SQLITE_DONE { report(.acknowledgmentFailed(code)); failed+=1 }
            else if result == .delivered { delivered+=1 } else if result != .discarded { failed+=1 }
            if result == .discarded {
                if dbQueue.sync(execute: { currentToken == token && currentURL == destination }) { onServerDataErased?() }
                break
            }
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
            guard !isDraining else { return false }
            var stmt:OpaquePointer?;defer{sqlite3_finalize(stmt)}
            guard sqlite3_prepare_v2(db,"DELETE FROM pending_events WHERE event_uuid=? AND synced=0 AND owner_id=? AND destination=?",-1,&stmt,nil)==SQLITE_OK else { return false }
            bind(stmt,1,uuid);bind(stmt,2,currentOwner ?? "");bind(stmt,3,currentURL)
            return sqlite3_step(stmt)==SQLITE_DONE && sqlite3_changes(db)>0
        }
    }

    public func isEventSynced(_ uuid: String) -> Bool {
        dbQueue.sync {
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT synced FROM pending_events WHERE event_uuid=? AND owner_id=? AND destination=?", -1, &stmt, nil) == SQLITE_OK else { return false }
            bind(stmt, 1, uuid); bind(stmt, 2, currentOwner ?? ""); bind(stmt, 3, currentURL)
            return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 1
        }
    }

    /// Drops pre-wipe pending events so offline data from before a server reset is never uploaded.
    public func purgeEventsCreatedBefore(isoUTC: String) {
        dbQueue.sync {
            guard let owner = currentOwner else { return }
            var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
            let sql = "UPDATE pending_events SET synced=1 WHERE synced=0 AND owner_id=? AND destination=? AND created_at_utc<=?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            bind(stmt, 1, owner); bind(stmt, 2, currentURL); bind(stmt, 3, isoUTC)
            sqlite3_step(stmt)
        }
    }

    /// Only migrate this owner's records after an authenticated address repair.
    func relocateDestination(from: String, to: String, owner: String) throws {
        try dbQueue.sync {
            guard !suspended, !isDraining else { throw QueueStorageError.unavailable }
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw QueueStorageError.unavailable }
            do {
                var stmt: OpaquePointer?
                let prepared = sqlite3_prepare_v2(db, "UPDATE pending_events SET destination=? WHERE destination=? AND owner_id=?", -1, &stmt, nil)
                guard prepared == SQLITE_OK else { throw QueueStorageError.writeFailed(prepared) }
                defer { sqlite3_finalize(stmt) }
                bind(stmt, 1, to); bind(stmt, 2, from); bind(stmt, 3, owner)
                let code = sqlite3_step(stmt)
                guard code == SQLITE_DONE else { throw QueueStorageError.writeFailed(code) }
                var version: OpaquePointer?; defer { sqlite3_finalize(version) }
                let preparedVersion = sqlite3_prepare_v2(db,"INSERT INTO server_generations(owner_id,destination,data_generation) SELECT owner_id,?,data_generation FROM server_generations WHERE owner_id=? AND destination=? ON CONFLICT(owner_id,destination) DO UPDATE SET data_generation=MAX(server_generations.data_generation,excluded.data_generation)",-1,&version,nil)
                guard preparedVersion == SQLITE_OK else { throw QueueStorageError.writeFailed(preparedVersion) }
                bind(version,1,to); bind(version,2,owner); bind(version,3,from)
                let versionCode = sqlite3_step(version)
                guard versionCode == SQLITE_DONE, sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw QueueStorageError.writeFailed(versionCode) }
            } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
            for (key, item) in volatile where item.owner == owner && item.destination == from {
                volatile.removeValue(forKey: key)
                volatile[owner+"|"+to+"|"+item.event.eventUUID] = Buffered(event: item.event, owner: owner, destination: to)
            }
            lastOwnerByDestination[to] = owner
        }
    }

    /// A reset must not race an already-sent request. Once suspended, stale
    /// producers cannot enqueue, retry buffered writes, or resume delivery.
    public func suspendForLocalReset() -> Bool {
        dbQueue.sync {
            guard !isDraining else { return false }
            suspended = true
            currentToken = ""
            return true
        }
    }

    public func resumeAfterFailedLocalReset(baseURL: String, token: String) {
        dbQueue.sync { suspended = false }
        configureSession(baseURL: baseURL, bearerToken: token)
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
