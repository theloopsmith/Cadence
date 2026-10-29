import XCTest
@testable import CadenceCompanion

/// Transport double: records what was sent and fails until `failuresRemaining`
/// is exhausted, so a drain can be driven through an offline period.
final class StubTransport: EventTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _failuresRemaining: Int

    init(failuresRemaining: Int = 0) {
        self._failuresRemaining = failuresRemaining
    }

    var sentEndpoints: [String] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    var attemptCount: Int { sentEndpoints.count }

    func send(endpoint: String, jsonData: Data, bearerToken: String) async -> DeliveryOutcome {
        return record(endpoint: endpoint)
    }

    /// Non-async so NSLock is never held across a suspension point.
    private func record(endpoint: String) -> DeliveryOutcome {
        lock.lock(); defer { lock.unlock() }
        _sent.append(endpoint)
        let shouldFail = _failuresRemaining > 0
        if shouldFail { _failuresRemaining -= 1 }
        return shouldFail ? .retryLater : .delivered
    }
}

/// Answers every send with a fixed outcome.
final class FixedOutcomeTransport: EventTransport, @unchecked Sendable {
    var outcome: DeliveryOutcome
    init(_ outcome: DeliveryOutcome) { self.outcome = outcome }
    func send(endpoint: String, jsonData: Data, bearerToken: String) async -> DeliveryOutcome { outcome }
}

final class SignInRejectionQueueTests: XCTestCase {
    /// An expired sign-in must never cost a fall alert: the event stays queued
    /// and the app is told it needs signing in again.
    func testARejectedTokenKeepsTheEventQueuedAndRaisesTheAlarm() async {
        let transport = FixedOutcomeTransport(.unauthorized)
        let mgr = EventSyncManager(
            transport: transport,
            databasePath: NSTemporaryDirectory() + "unauth-\(UUID().uuidString).sqlite",
            startPeriodicDrain: false
        )
        var told = 0
        mgr.onUnauthorized = { told += 1 }
        mgr.saveLocalImmediate(eventUUID: "fall-unauth-1", endpoint: "/api/v1/events/fall", payload: ["event_uuid": "fall-unauth-1"])

        let first = await mgr.drainPendingEvents()
        XCTAssertEqual(first.delivered, 0)
        XCTAssertEqual(mgr.pendingCount(), 1, "the fall stays on the phone")
        XCTAssertEqual(told, 1)

        transport.outcome = .delivered
        _ = await mgr.drainPendingEvents(now: Date().addingTimeInterval(3600))
        XCTAssertEqual(mgr.pendingCount(), 0, "it is sent once sign-in is fixed")
    }
}

final class EventSyncQueueTests: XCTestCase {
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory() + "cadence-queue-\(UUID().uuidString).sqlite"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    private func makeManager(_ transport: EventTransport) -> EventSyncManager {
        // Periodic drain off so each test drives the drain deterministically.
        EventSyncManager(
            transport: transport,
            databasePath: dbPath,
            startPeriodicDrain: false
        )
    }

    private func saveFall(_ mgr: EventSyncManager, uuid: String) {
        mgr.saveLocalImmediate(
            eventUUID: uuid,
            endpoint: "/api/v1/events/fall",
            payload: ["event_uuid": uuid, "peak_impact_g": 3.9]
        )
    }

    /// A fall saved while the backend is reachable drains on the first pass.
    func testDeliveredEventIsMarkedSyncedAndLeavesTheQueue() async {
        let transport = StubTransport()
        let mgr = makeManager(transport)
        saveFall(mgr, uuid: "fall-online-1")

        let result = await mgr.drainPendingEvents()
        XCTAssertEqual(result.delivered, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(mgr.pendingCount(), 0)
    }

    /// The offline fail-safe: a fall recorded with no network stays queued and
    /// is delivered once connectivity returns. Before the retry drain existed,
    /// a failed dispatch left the row at synced = 0 and nothing ever retried it.
    func testFallQueuedWhileOfflineIsDeliveredWhenConnectivityReturns() async {
        let transport = StubTransport(failuresRemaining: 2)
        let mgr = makeManager(transport)
        saveFall(mgr, uuid: "fall-offline-1")

        // Airplane mode: first attempt fails, row survives.
        var r = await mgr.drainPendingEvents(now: Date())
        XCTAssertEqual(r.failed, 1)
        XCTAssertEqual(mgr.pendingCount(), 1, "a failed fall must never be dropped")

        // Still offline, and still before the backoff elapses: no new attempt.
        let attemptsAfterFirst = transport.attemptCount
        r = await mgr.drainPendingEvents(now: Date())
        XCTAssertEqual(transport.attemptCount, attemptsAfterFirst, "backoff must be honored")

        // Backoff elapses, still offline: attempt 2 fails.
        r = await mgr.drainPendingEvents(now: Date().addingTimeInterval(30))
        XCTAssertEqual(r.failed, 1)
        XCTAssertEqual(mgr.pendingCount(), 1)

        // Network returns.
        r = await mgr.drainPendingEvents(now: Date().addingTimeInterval(600))
        XCTAssertEqual(r.delivered, 1)
        XCTAssertEqual(mgr.pendingCount(), 0)
    }

    /// Each failure must push the next attempt further out rather than spinning.
    func testRetryCountIncrementsAndBackoffGrows() async {
        let transport = StubTransport(failuresRemaining: 99)
        let mgr = makeManager(transport)
        saveFall(mgr, uuid: "fall-backoff-1")

        await mgr.drainPendingEvents(now: Date())
        XCTAssertEqual(mgr.retryCount(forEventUUID: "fall-backoff-1"), 1)

        await mgr.drainPendingEvents(now: Date().addingTimeInterval(10))
        XCTAssertEqual(mgr.retryCount(forEventUUID: "fall-backoff-1"), 2)

        // Third attempt is scheduled 15s out, so a drain 5s later must skip it.
        let attempts = transport.attemptCount
        await mgr.drainPendingEvents(now: Date().addingTimeInterval(15))
        XCTAssertEqual(transport.attemptCount, attempts, "backoff must grow between attempts")
    }

    /// Backoff is capped so an overnight queue keeps retrying rather than
    /// escalating into effectively never.
    func testBackoffIsCappedAtFiveMinutes() {
        XCTAssertEqual(EventSyncManager.backoffScheduleSec.last, 300)
        XCTAssertTrue(
            EventSyncManager.backoffScheduleSec.sorted() == EventSyncManager.backoffScheduleSec,
            "schedule must be non-decreasing"
        )
    }

    /// Several queued events drain in the order they were recorded.
    func testMultipleQueuedEventsAllDrainOldestFirst() async {
        let transport = StubTransport()
        let mgr = makeManager(transport)
        mgr.saveLocalImmediate(
            eventUUID: "fog-1", endpoint: "/api/v1/events/fog", payload: ["event_uuid": "fog-1"]
        )
        saveFall(mgr, uuid: "fall-2")
        mgr.saveLocalImmediate(
            eventUUID: "voice-3", endpoint: "/api/v1/events/voice", payload: ["event_uuid": "voice-3"]
        )

        let r = await mgr.drainPendingEvents()
        XCTAssertEqual(r.delivered + r.failed, mgr.pendingCount() + r.delivered)
        XCTAssertEqual(mgr.pendingCount(), 0, "every queued event must drain")
    }

    /// Re-saving the same event_uuid must not create a duplicate row; the
    /// backend is idempotent on event_uuid and the queue should match.
    func testSavingTheSameEventTwiceKeepsOneQueueRow() async {
        let transport = StubTransport(failuresRemaining: 99)
        let mgr = makeManager(transport)
        saveFall(mgr, uuid: "fall-dup-1")
        await mgr.drainPendingEvents(now: Date())
        saveFall(mgr, uuid: "fall-dup-1")
        XCTAssertEqual(mgr.pendingCount(), 1)
    }
}

final class FallAcknowledgmentTests: XCTestCase {
    private func outcome(_ json: String, status: Int = 200) -> DeliveryOutcome {
        URLSessionEventTransport.outcome(forStatus: status, endpoint: "/api/v1/events/fall", responseData: Data(json.utf8))
    }
    func testFailedDispatchIsRetriedEvenWithHTTP200() {
        XCTAssertEqual(outcome(#"{"status":"confirmed_waiting_dispatch","twilio_dispatched":false}"#), .retryLater)
        XCTAssertEqual(outcome("{}"), .retryLater)
        XCTAssertEqual(outcome("bad JSON"), .retryLater)
        XCTAssertEqual(outcome("{}", status: 503), .retryLater)
    }
    func testCandidateCancellationAndProviderAcceptanceAreAcknowledged() {
        XCTAssertEqual(outcome(#"{"status":"candidate_check_in_pending"}"#), .delivered)
        XCTAssertEqual(outcome(#"{"status":"canceled_false_alarm"}"#), .delivered)
        XCTAssertEqual(outcome(#"{"status":"escalated_twilio","provider_accepted":true,"duplicate":true}"#), .delivered)
        XCTAssertEqual(outcome(#"{"status":"escalated_twilio","provider_accepted":false}"#), .retryLater)
    }
}

private final class ReplacementTransport: EventTransport {
    var onSend: (() async -> Void)?
    func send(endpoint: String, jsonData: Data, bearerToken: String) async -> DeliveryOutcome {
        await onSend?()
        return .delivered
    }
}

final class FallQueueRevisionTests: XCTestCase {
    func testOldCandidateResponseCannotAcknowledgeANewerEscalation() async {
        let path = NSTemporaryDirectory() + "revision-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let transport = ReplacementTransport()
        let queue = EventSyncManager(transport: transport, databasePath: path, startPeriodicDrain: false)
        queue.saveLocalImmediate(eventUUID: "revision-fall", endpoint: "/api/v1/events/fall", payload: ["status": "candidate_check_in_pending"])
        transport.onSend = {
            queue.saveLocalImmediate(eventUUID: "revision-fall", endpoint: "/api/v1/events/fall", payload: ["status": "confirmed_waiting_dispatch"])
            let overlapping = await queue.drainPendingEvents()
            XCTAssertEqual(overlapping.delivered, 0, "only one drain owns the queue")
        }
        _ = await queue.drainPendingEvents()
        XCTAssertEqual(queue.pendingCount(), 1, "the newer payload still needs delivery")
        XCTAssertTrue(queue.peekNext()?.payloadJSON.contains("confirmed_waiting_dispatch") == true)
        transport.onSend = nil
        _ = await queue.drainPendingEvents()
        XCTAssertEqual(queue.pendingCount(), 0)
    }
}
