import XCTest
import SQLite3
@testable import CadenceCompanion

private final class GenerationTransport: DataGenerationTransport {
    var generation = 0
    var outcome: DeliveryOutcome = .delivered
    var sent: [(endpoint: String, body: Data, generation: Int)] = []
    var beforeFetch: (() async -> Void)?
    var beforeSend: (() async -> Void)?
    func fetchDataGeneration(bearerToken: String) async throws -> Int {
        await beforeFetch?()
        return generation
    }
    func send(endpoint: String, jsonData: Data, bearerToken: String) async -> DeliveryOutcome {
        XCTFail("Production queues must use the versioned send")
        return .retryLater
    }
    func send(endpoint: String, jsonData: Data, bearerToken: String, dataGeneration: Int) async -> DeliveryOutcome {
        sent.append((endpoint,jsonData,dataGeneration))
        await beforeSend?()
        return outcome
    }
}

private final class GenerationJSONTransport: JSONTransporting {
    var requests: [URLRequest] = []
    var error: Error? = CadenceAPIError.dataGenerationChanged(1)
    func send(_ request: URLRequest, bearerToken: String) async throws -> Data {
        requests.append(request)
        if let error { throw error }
        return Data(#"{"status":"logged"}"#.utf8)
    }
}

private struct ErasedExamSubmitter: ExamSubmitting {
    func submit(examJSON: Data, bearerToken: String) async throws -> HomeMotorExamResult? {
        throw CadenceAPIError.dataGenerationChanged(1)
    }
}

private final class PausedGenerationExam: ExamSubmitting {
    let started: XCTestExpectation
    var reply: CheckedContinuation<HomeMotorExamResult?, Never>?
    init(_ started: XCTestExpectation) { self.started = started }
    func submit(examJSON: Data, bearerToken: String) async -> HomeMotorExamResult? {
        await withCheckedContinuation { reply = $0; started.fulfill() }
    }
}

@MainActor
final class DataGenerationTests: XCTestCase {
    private let url = "http://localhost:8000"
    private let token = "generation-test-owner"
    private func queue(_ transport: GenerationTransport, path: String? = nil) -> EventSyncManager {
        let queue = EventSyncManager(transport: transport,
            databasePath: path ?? NSTemporaryDirectory()+"generation-\(UUID()).sqlite", startPeriodicDrain: false)
        queue.configureSession(baseURL: url, bearerToken: token, replaceTransport: false)
        return queue
    }

    func testEraseRetiresOldFutureDatedActionsWithoutReportingDeliveryAndAllowsNewActions() async {
        let transport = GenerationTransport(); let queue = queue(transport)
        _ = queue.saveLocalImmediate(eventUUID: "old", endpoint: "/api/v1/events/fog", payload: ["timestamp_utc":"2099-01-01T00:00:00Z"])
        transport.generation = 1
        let result = await queue.drainPendingEvents()
        XCTAssertEqual(result.delivered, 0)
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertEqual(queue.pendingCount(), 0)
        XCTAssertFalse(queue.isEventSynced("old"), "discarded is not delivered")
        XCTAssertEqual(queue.currentDataGeneration, 1)
        _ = queue.saveLocalImmediate(eventUUID: "new", endpoint: "/fixture", payload: ["timestamp_utc":"2000-01-01T00:00:00Z"])
        let fresh = await queue.drainPendingEvents()
        XCTAssertEqual(fresh.delivered, 1)
        XCTAssertEqual(transport.sent.map(\.generation), [1])
    }

    func testGenerationPersistsAndAnOldIncidentFollowupIsNeverRestamped() async {
        let path = NSTemporaryDirectory()+"persist-generation-\(UUID()).sqlite"
        let transport = GenerationTransport(); let queue = queue(transport, path: path)
        _ = queue.saveLocalImmediate(eventUUID: "old-incident", endpoint: "/fixture", payload: ["status":"first"])
        transport.generation = 2; _ = await queue.drainPendingEvents()
        let reopened = self.queue(transport, path: path)
        XCTAssertEqual(reopened.currentDataGeneration, 2)
        XCTAssertFalse(reopened.observeDataGeneration(1, bearerToken: token, baseURL: url))
        _ = reopened.saveLocalImmediate(eventUUID: "old-incident", endpoint: "/fixture", payload: ["status":"later"])
        XCTAssertEqual(reopened.dueEvents().first?.dataGeneration, 0)
        _ = await reopened.drainPendingEvents()
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testGenerationLearningIsOwnerAndDestinationBoundAndMovesWithVerifiedAddress() throws {
        let transport = GenerationTransport(); let queue = queue(transport)
        XCTAssertTrue(queue.observeDataGeneration(3, bearerToken: token, baseURL: url))
        queue.configureSession(baseURL: url, bearerToken: "other", replaceTransport: false)
        XCTAssertFalse(queue.observeDataGeneration(4, bearerToken: token, baseURL: url))
        XCTAssertEqual(queue.currentDataGeneration, 0)
        queue.configureSession(baseURL: url, bearerToken: token, replaceTransport: false)
        try queue.relocateDestination(from: url, to: "http://mac.local:8001", owner: EventSyncManager.owner(for: token)!)
        queue.configureSession(baseURL: "http://mac.local:8001", bearerToken: token, replaceTransport: false)
        XCTAssertEqual(queue.currentDataGeneration, 3)
    }

    func testWipeAfterPreflightIsTerminalAndNeverReportedAsAccepted() async {
        let transport = GenerationTransport(); let queue = queue(transport)
        transport.outcome = .discarded
        _ = queue.saveLocalImmediate(eventUUID: "racing", endpoint: "/fixture", payload: [:])
        let result = await queue.drainPendingEvents()
        XCTAssertEqual(result.delivered, 0)
        XCTAssertFalse(queue.isEventSynced("racing"))
        XCTAssertEqual(queue.pendingCount(), 0)
        _ = await queue.drainPendingEvents()
        XCTAssertEqual(transport.sent.count, 1)
        let erased = Data(#"{"error":"data_generation_changed","data_generation":1}"#.utf8)
        XCTAssertEqual(URLSessionEventTransport.outcome(forStatus: 409, endpoint: "/fixture", responseData: erased), .discarded)
        XCTAssertEqual(URLSessionEventTransport.outcome(forStatus: 409, endpoint: "/fixture", responseData: Data(#"{"error":"conflict"}"#.utf8)), .retryLater)
        XCTAssertEqual(URLSessionEventTransport.outcome(forStatus: 200, endpoint: "/api/v1/events/fall", responseData: Data(#"{"status":"dropped_wiped"}"#.utf8)), .discarded)
    }

    func testSignOutDuringGenerationFetchCannotDiscardAnotherSessionOrSend() async {
        let transport = GenerationTransport(); let queue = queue(transport)
        let started = expectation(description: "fetch started")
        var release: CheckedContinuation<Void, Never>?
        transport.beforeFetch = { await withCheckedContinuation { release = $0; started.fulfill() } }
        transport.generation = 4
        _ = queue.saveLocalImmediate(eventUUID: "held", endpoint: "/fixture", payload: [:])
        let drain = Task { await queue.drainPendingEvents() }
        await fulfillment(of: [started], timeout: 2)
        queue.configureSession(baseURL: url, bearerToken: "", replaceTransport: false)
        release?.resume(); _ = await drain.value
        XCTAssertEqual(queue.currentDataGeneration, 0)
        XCTAssertEqual(queue.pendingCount(), 1)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testInteractiveEraseConflictLearnsGenerationWithoutRetryingTheOldAction() async throws {
        let transport = GenerationTransport(); let queue = queue(transport)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "generation-api-\(UUID())")!, sync: queue,
            tokenStore: InMemoryTokenStore(token: token), defaultToken: "")
        let json = GenerationJSONTransport(); settings.apiTransport = json
        _ = queue.saveLocalImmediate(eventUUID: "old", endpoint: "/fixture", payload: [:])
        do { try await settings.api.logDose(); XCTFail("old action must not succeed") }
        catch CadenceAPIError.dataGenerationChanged(let value) { XCTAssertEqual(value, 1) }
        XCTAssertEqual(json.requests.count, 1)
        XCTAssertEqual(json.requests[0].value(forHTTPHeaderField: "X-Cadence-Data-Generation"), "0")
        XCTAssertEqual(queue.currentDataGeneration, 1)
        XCTAssertEqual(queue.pendingCount(), 0)
        json.error = nil
        try await settings.api.logDose()
        XCTAssertEqual(json.requests[1].value(forHTTPHeaderField: "X-Cadence-Data-Generation"), "1")
    }

    func testErasedInteractiveExamIsLocalOnlyAndIsNotQueuedAsOffline() async {
        let transport = GenerationTransport(); let queue = queue(transport)
        let manager = HomeMotorExamManager(submitter: ErasedExamSubmitter(), sync: queue)
        manager.deviceBearerToken = token
        _ = await manager.completeExam(examUUID: "erased-exam")
        XCTAssertEqual(queue.currentDataGeneration, 1)
        XCTAssertEqual(queue.pendingCount(), 0)
        XCTAssertNotNil(manager.lastRecord)
        XCTAssertTrue(manager.lastResultSummary?.contains("not restored") == true)
    }

    func testOfflineExamCompletingAcrossEraseKeepsItsOriginalGeneration() async {
        let transport = GenerationTransport(); let queue = queue(transport)
        let started = expectation(description: "exam sent")
        let submitter = PausedGenerationExam(started)
        let manager = HomeMotorExamManager(submitter: submitter, sync: queue); manager.deviceBearerToken = token
        let task = Task { await manager.completeExam(examUUID: "old-exam") }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(queue.observeDataGeneration(1, bearerToken: token, baseURL: url))
        submitter.reply?.resume(returning: nil); _ = await task.value
        XCTAssertEqual(queue.dueEvents().first?.dataGeneration, 0)
        transport.generation = 1; _ = await queue.drainPendingEvents()
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testUndoWhileDoseUploadIsInflightQueuesACorrelatedRetraction() async throws {
        let transport = GenerationTransport(); let queue = queue(transport)
        let diary = DiaryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("undo-race-\(UUID())"))
        let model = DoseLogModel(schedule: MedicationSchedule(medicationName: "Fixture", doseTimes: []), diary: diary, sync: queue)
        model.markTaken()
        let original = try XCTUnwrap(queue.dueEvents().first)
        let started = expectation(description: "dose uploading")
        var release: CheckedContinuation<Void, Never>?
        transport.beforeSend = { await withCheckedContinuation { release = $0; started.fulfill() } }
        let drain = Task { await queue.drainPendingEvents() }
        await fulfillment(of: [started], timeout: 2)
        model.undo()
        release?.resume(); _ = await drain.value
        let retraction = try XCTUnwrap(queue.dueEvents().first)
        XCTAssertEqual(retraction.endpoint, "/api/v1/medication/dose/retract")
        let body = try JSONSerialization.jsonObject(with: Data(retraction.payloadJSON.utf8)) as! [String:Any]
        XCTAssertEqual(body["retracted_event_uuid"] as? String, original.eventUUID)
        XCTAssertTrue(queue.isEventSynced(original.eventUUID))
        XCTAssertTrue(try diary.events(on: Date()).isEmpty)
    }

    func testGenerationWriteFailureDoesNotForgetOrSendPendingRecords() async throws {
        let path = NSTemporaryDirectory()+"generation-write-failure-\(UUID()).sqlite"
        let transport = GenerationTransport(); let queue = queue(transport, path: path)
        _ = queue.saveLocalImmediate(eventUUID: "held-for-storage", endpoint: "/fixture", payload: [:])
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database,"CREATE TRIGGER fail_generation BEFORE INSERT ON server_generations BEGIN SELECT RAISE(ABORT,'fixture disk failure'); END",nil,nil,nil),SQLITE_OK)
        sqlite3_close(database)
        transport.generation = 1
        let result = await queue.drainPendingEvents()
        XCTAssertEqual(result.delivered, 0)
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertEqual(queue.pendingCount(), 1)
        XCTAssertEqual(queue.currentDataGeneration, 0)
        XCTAssertNotNil(queue.persistenceError)
    }

    func testAddressRepairCannotDowngradeTheEraseHistory() async throws {
        let transport = GenerationTransport(); let queue = queue(transport)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "generation-move-\(UUID())")!, sync: queue,
            tokenStore: InMemoryTokenStore(token: token), defaultToken: "")
        XCTAssertTrue(queue.observeDataGeneration(3, bearerToken: token, baseURL: url))
        let json = RecordingJSONTransport()
        json.responses = [try JSONSerialization.data(withJSONObject: ["service":"cadence-accessibility-companion",
            "server_id":UUID().uuidString,"patient_id":"fixture","data_generation":2])]
        settings.apiTransport = json
        let changed = await settings.connectServer(to: "http://mac.local:8001", repairLocalhost: true)
        XCTAssertFalse(changed)
        XCTAssertEqual(settings.api.baseURL, url)
        XCTAssertNil(settings.profile.pendingServerMove)
        XCTAssertEqual(queue.currentDataGeneration, 3)
    }
}
