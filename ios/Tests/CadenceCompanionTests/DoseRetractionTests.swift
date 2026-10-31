import Foundation
import XCTest
@testable import CadenceCompanion

private final class MockSyncTransport: EventTransport {
    struct Post {
        let endpoint: String
        let json: Data
        let token: String
    }
    var posts: [Post] = []
    var outcome: DeliveryOutcome = .delivered

    func send(endpoint: String, jsonData: Data, bearerToken: String) async -> DeliveryOutcome {
        posts.append(Post(endpoint: endpoint, json: jsonData, token: bearerToken))
        return outcome
    }
}

@MainActor
final class DoseRetractionTests: XCTestCase {
    private func makeToken(_ user: String = "wearer-01") -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["sub": user, "pid": "wearer", "generation": 0])
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "e30.\(payload).test-signature"
    }

    private func make(now: Date) -> (DoseLogModel, DiaryStore, EventSyncManager, MockSyncTransport) {
        let diary = DiaryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retract-diary-\(UUID().uuidString)"))
        let transport = MockSyncTransport()
        let sync = EventSyncManager(
            transport: transport,
            databasePath: NSTemporaryDirectory() + "retract-sync-\(UUID().uuidString).sqlite",
            startPeriodicDrain: false
        )
        sync.deviceBearerToken = makeToken()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let schedule = MedicationSchedule(
            medicationName: "Levodopa",
            doseTimes: [DoseTime(hour: 8, minute: 0), DoseTime(hour: 12, minute: 30)],
            calendar: cal
        )
        let model = DoseLogModel(schedule: schedule, diary: diary, sync: sync, clock: { now })
        return (model, diary, sync, transport)
    }

    func testFailedDiaryWriteCannotProduceAConfirmedDoseOrQueueUpload() throws {
        let now = dateAt(hour: 8, minute: 0)
        let (model, diary, sync, _) = make(now: now)
        try Data("blocked directory".utf8).write(to: diary.directory)
        XCTAssertFalse(model.markTaken())
        XCTAssertTrue(model.takenToday.isEmpty)
        XCTAssertFalse(model.canUndo)
        XCTAssertEqual(sync.pendingCount(), 0)
        XCTAssertNotNil(model.saveError)
        try FileManager.default.removeItem(at: diary.directory)
        XCTAssertTrue(model.markTaken())
        XCTAssertEqual(try diary.events(on: now).filter { $0.kind == .doseTaken }.count, 1)
    }

    func testUnreadableHistoryIsNotReportedAsAConfirmedEmptyRoutine() throws {
        let now = dateAt(hour: 8, minute: 0)
        let (_, diary, sync, _) = make(now: now)
        try Data("blocked directory".utf8).write(to: diary.directory)
        let model = DoseLogModel(schedule: MedicationSchedule(medicationName: "Fixture", doseTimes: [DoseTime(hour: 8, minute: 0)]),
                                 diary: diary, sync: sync, clock: { now })
        XCTAssertFalse(model.isDoseDue)
        XCTAssertNotNil(model.saveError)
        XCTAssertEqual(model.headline, "Medication history unavailable")
    }

    private func dateAt(hour: Int, minute: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 29; c.hour = hour; c.minute = minute
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testUndoBeforeSyncWithdrawsLocalPendingDose() {
        let now = dateAt(hour: 8, minute: 5)
        let (model, diary, sync, _) = make(now: now)

        model.markTaken()
        XCTAssertEqual(sync.pendingCount(), 1)
        XCTAssertEqual(try diary.events(on: now).count, 1)

        // Undo immediately while offline / before drain
        model.undo()

        // Dose must be withdrawn directly, no retraction needed because server never saw it
        XCTAssertEqual(sync.pendingCount(), 0)
        XCTAssertEqual(try diary.events(on: now).count, 0)
        XCTAssertTrue(model.isDoseDue)
    }

    func testUndoAfterSyncQueuesIdempotentRetraction() async {
        let now = dateAt(hour: 8, minute: 5)
        let (model, diary, sync, transport) = make(now: now)

        model.markTaken()
        XCTAssertEqual(sync.pendingCount(), 1)

        // Sync the dose to the backend
        let (delivered, _) = await sync.drainPendingEvents(now: now)
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(sync.pendingCount(), 0)
        XCTAssertEqual(transport.posts.count, 1)
        XCTAssertEqual(transport.posts[0].endpoint, "/api/v1/medication/dose")

        // User now taps Undo on a dose that already reached the backend
        model.undo()

        // Local diary is cleared
        XCTAssertEqual(try diary.events(on: now).count, 0)
        // A retraction event is enqueued for server synchronization
        XCTAssertEqual(sync.pendingCount(), 1)

        // Drain the queue to deliver the retraction
        let (retractDelivered, _) = await sync.drainPendingEvents(now: now)
        XCTAssertEqual(retractDelivered, 1)
        XCTAssertEqual(sync.pendingCount(), 0)
        XCTAssertEqual(transport.posts.count, 2)
        XCTAssertEqual(transport.posts[1].endpoint, "/api/v1/medication/dose/retract")

        let retractPayload = try? JSONSerialization.jsonObject(with: transport.posts[1].json) as? [String: Any]
        XCTAssertNotNil(retractPayload?["retracted_event_uuid"])
        XCTAssertEqual(retractPayload?["reason"] as? String, "user_undo")
    }

    func testPurgeEventsCreatedBeforeWipeTimestamp() {
        let sync = EventSyncManager(
            databasePath: NSTemporaryDirectory() + "wipe-purge-\(UUID().uuidString).sqlite",
            startPeriodicDrain: false
        )
        sync.deviceBearerToken = makeToken("wearer-wipe")

        // Save two events
        _ = sync.saveLocalImmediate(eventUUID: "evt-old", endpoint: "/api/v1/events/fog", payload: ["event_uuid": "evt-old"])
        _ = sync.saveLocalImmediate(eventUUID: "evt-new", endpoint: "/api/v1/events/fog", payload: ["event_uuid": "evt-new"])

        XCTAssertEqual(sync.pendingCount(), 2)

        // Purge with future date so all pre-existing events are pruned
        let futureISO = "2099-01-01T00:00:00Z"
        sync.purgeEventsCreatedBefore(isoUTC: futureISO)

        XCTAssertEqual(sync.pendingCount(), 0)
    }
}
