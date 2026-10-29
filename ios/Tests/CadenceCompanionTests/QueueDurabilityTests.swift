import XCTest
import SQLite3
@testable import CadenceCompanion

private final class SessionTransport: EventTransport {
    var tokens: [String] = []
    var onSend: (() -> Void)?
    var outcome: DeliveryOutcome = .delivered
    func send(endpoint: String, jsonData: Data, bearerToken: String) async -> DeliveryOutcome {
        tokens.append(bearerToken); onSend?(); return outcome
    }
}

final class QueueDurabilityTests: XCTestCase {
    private func token(_ user: String, patient: String = "wearer", generation: Int = 0) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["sub":user,"pid":patient,"generation":generation])
        let payload=data.base64EncodedString().replacingOccurrences(of:"=",with:"").replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_")
        return "e30.\(payload).test-signature"
    }
    private func path()->String { NSTemporaryDirectory()+"queue-durability-\(UUID().uuidString).sqlite" }

    func testAnotherAccountCannotDrainOrWithdrawTheFirstAccountsEvents() async {
        let transport=SessionTransport(); let q=EventSyncManager(transport:transport,databasePath:path(),startPeriodicDrain:false)
        q.deviceBearerToken=token("A")
        q.saveLocalImmediate(eventUUID:"event-A",endpoint:"/api/v1/events/fall",payload:["status":"candidate_check_in_pending"])
        q.deviceBearerToken=token("B")
        XCTAssertTrue(q.dueEvents().isEmpty)
        XCTAssertFalse(q.withdrawPending("event-A"))
        _ = await q.drainPendingEvents()
        XCTAssertTrue(transport.tokens.isEmpty)
        q.deviceBearerToken=token("A",generation:2)
        _ = await q.drainPendingEvents()
        XCTAssertEqual(transport.tokens,[token("A",generation:2)])
        XCTAssertEqual(q.pendingCount(),0)
    }
    func testSameUsernameDifferentWearerAndDifferentServerAreIsolated() {
        let q=EventSyncManager(databasePath:path(),startPeriodicDrain:false)
        q.deviceBearerToken=token("same",patient:"first")
        q.saveLocalImmediate(eventUUID:"first",endpoint:"/event",payload:[:])
        q.deviceBearerToken=token("same",patient:"second")
        XCTAssertTrue(q.dueEvents().isEmpty)
        q.configureSession(baseURL:"https://other.example",bearerToken:token("same",patient:"first"))
        XCTAssertTrue(q.dueEvents().isEmpty)
    }
    func testSignedOutEventsRemainBoundToThePreviousAccountAfterRelaunch() {
        let dbPath=path()
        do {
            let q=EventSyncManager(databasePath:dbPath,startPeriodicDrain:false)
            q.deviceBearerToken=token("A"); q.deviceBearerToken=""
            q.saveLocalImmediate(eventUUID:"offline-A",endpoint:"/event",payload:[:])
            XCTAssertTrue(q.dueEvents().isEmpty)
        }
        let reopened=EventSyncManager(databasePath:dbPath,startPeriodicDrain:false)
        reopened.deviceBearerToken=token("B")
        XCTAssertTrue(reopened.dueEvents().isEmpty)
        reopened.deviceBearerToken=token("A")
        XCTAssertEqual(reopened.dueEvents().map(\.eventUUID),["offline-A"])
    }
    func testSwitchDuringARequestNeverSendsRemainingRowsWithNewCredentials() async {
        let transport=SessionTransport();let q=EventSyncManager(transport:transport,databasePath:path(),startPeriodicDrain:false)
        let first=token("A");let second=token("B")
        q.deviceBearerToken=first
        for id in ["A-1","A-2"] { q.saveLocalImmediate(eventUUID:id,endpoint:"/event",payload:[:]) }
        transport.onSend={ q.deviceBearerToken=second }
        _ = await q.drainPendingEvents()
        XCTAssertEqual(transport.tokens,[first])
        XCTAssertTrue(q.dueEvents().isEmpty)
        q.deviceBearerToken=first
        XCTAssertEqual(q.dueEvents().count,1)
    }
    func testUnauthorizedOldRequestDoesNotExpireANewSignIn() async {
        let transport=SessionTransport();let q=EventSyncManager(transport:transport,databasePath:path(),startPeriodicDrain:false)
        q.deviceBearerToken=token("A")
        q.saveLocalImmediate(eventUUID:"A",endpoint:"/event",payload:[:])
        transport.onSend={q.deviceBearerToken=self.token("B")};transport.outcome = .unauthorized
        var expired=false;q.onUnauthorized={expired=true}
        _ = await q.drainPendingEvents()
        XCTAssertFalse(expired)
    }
    func testLegacyRowsAreQuarantinedRatherThanAssignedToTheNextLogin() {
        let dbPath=path();var db:OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath,&db),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE pending_events(event_uuid TEXT PRIMARY KEY,endpoint TEXT NOT NULL,payload_json TEXT NOT NULL,created_at_utc TEXT NOT NULL,retry_count INTEGER DEFAULT 0,synced INTEGER DEFAULT 0); INSERT INTO pending_events VALUES('legacy','/event','{}','2026-10-28T00:00:00Z',0,0);",nil,nil,nil),SQLITE_OK)
        sqlite3_close(db)
        let q=EventSyncManager(databasePath:dbPath,startPeriodicDrain:false)
        q.deviceBearerToken=token("new-login")
        XCTAssertEqual(q.quarantinedCount(),1)
        XCTAssertEqual(q.pendingCount(),1)
        XCTAssertTrue(q.dueEvents().isEmpty)
    }
    func testFailedDiskSaveIsExplicitAndVolatileRecoveryPreservesItsOwner() throws {
        let dbPath=path();try FileManager.default.createDirectory(atPath:dbPath,withIntermediateDirectories:true)
        let q=EventSyncManager(databasePath:dbPath,startPeriodicDrain:false)
        q.deviceBearerToken=token("A")
        var notified=false;q.onPersistenceFailure={_ in notified=true}
        let result=q.saveLocalImmediate(eventUUID:"disk-A",endpoint:"/api/v1/events/fall",payload:["status":"confirmed_waiting_dispatch"])
        guard case .failure = result else {return XCTFail("must not claim a disk save")}
        XCTAssertTrue(notified);XCTAssertNotNil(q.persistenceError);XCTAssertEqual(q.volatileEventCount,1)
        q.deviceBearerToken=token("B")
        try FileManager.default.removeItem(atPath:dbPath)
        q.retryPersistingBufferedEvents()
        XCTAssertTrue(q.dueEvents().isEmpty)
        q.deviceBearerToken=token("A")
        XCTAssertEqual(q.dueEvents().map(\.eventUUID),["disk-A"])
        XCTAssertEqual(q.volatileEventCount,0)
    }
    func testLockedDatabaseRetainsEventAndRetriesAfterTheLockIsReleased() {
        let dbPath=path();let q=EventSyncManager(databasePath:dbPath,startPeriodicDrain:false)
        var lock:OpaquePointer?;sqlite3_open(dbPath,&lock)
        XCTAssertEqual(sqlite3_exec(lock,"BEGIN EXCLUSIVE",nil,nil,nil),SQLITE_OK)
        let result=q.saveLocalImmediate(eventUUID:"locked",endpoint:"/api/v1/events/fall",payload:[:])
        guard case .failure = result else {sqlite3_close(lock);return XCTFail("must expose write failure")}
        XCTAssertEqual(q.volatileEventCount,1)
        sqlite3_exec(lock,"ROLLBACK",nil,nil,nil);sqlite3_close(lock)
        q.retryPersistingBufferedEvents()
        XCTAssertEqual(q.dueEvents().map(\.eventUUID),["locked"])
    }
    func testInvalidJSONIsReportedRatherThanMarkedSaved() {
        let q=EventSyncManager(databasePath:path(),startPeriodicDrain:false)
        let result=q.saveLocalImmediate(eventUUID:"nan",endpoint:"/event",payload:["value":Double.nan])
        guard case .failure(.invalidPayload) = result else {return XCTFail("must reject unpersistable payload")}
    }
}
