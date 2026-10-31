import XCTest
@testable import CadenceCompanion

// MARK: - Background keep-alive

final class RecordingKeepAlive: BackgroundKeepAliving {
    private(set) var isActive = false
    var starts = 0
    var stops = 0
    func start() { isActive = true; starts += 1 }
    func stop() { isActive = false; stops += 1 }
}

@MainActor
final class ProtectionKeepAliveTests: XCTestCase {
    private func make() -> (WalkingModel, MotionFeed, RecordingKeepAlive) {
        let feed = MotionFeed()
        let keepAlive = RecordingKeepAlive()
        let fall = FallAlertCoordinator(
            screen: NoopScreenController(), dialer: RecordingPhoneDialer(),
            sync: EventSyncManager(
                databasePath: NSTemporaryDirectory() + "ka-\(UUID().uuidString).sqlite", startPeriodicDrain: false
            ),
            locationProvider: MockLocationProvider(), speechListener: MockSpeechCheckInListener()
        )
        let glasses = GlassesSessionManager(phoneMotion: MockMotionSource(available: true))
        let model = WalkingModel(
            motion: feed, fallAlert: fall, location: MockLocationProvider(), glasses: glasses, keepAlive: keepAlive
        )
        return (model, feed, keepAlive)
    }

    /// While protection streams, the app must not be suspended when the
    /// screen locks: the keep-alive runs exactly as long as the stream does.
    func testKeepAliveFollowsProtection() {
        let (model, feed, keepAlive) = make()
        XCTAssertFalse(keepAlive.isActive)

        model.setProtection(enabled: true)
        XCTAssertEqual(feed.isRunning, true)
        XCTAssertTrue(keepAlive.isActive, "a running stream needs the keep-alive")

        model.setProtection(enabled: false)
        XCTAssertFalse(keepAlive.isActive)
        XCTAssertEqual(keepAlive.starts, 1)
        XCTAssertEqual(keepAlive.stops, 1)
    }

    func testAFailedStartDoesNotLeaveTheKeepAliveRunning() {
        let feed = MotionFeed()
        let keepAlive = RecordingKeepAlive()
        let fall = FallAlertCoordinator(
            screen: NoopScreenController(), dialer: RecordingPhoneDialer(),
            sync: EventSyncManager(
                databasePath: NSTemporaryDirectory() + "ka-\(UUID().uuidString).sqlite", startPeriodicDrain: false
            ),
            locationProvider: MockLocationProvider(), speechListener: MockSpeechCheckInListener()
        )
        let glasses = GlassesSessionManager(phoneMotion: MockMotionSource(available: false))
        let model = WalkingModel(
            motion: feed, fallAlert: fall, location: MockLocationProvider(), glasses: glasses, keepAlive: keepAlive
        )
        model.setProtection(enabled: true)
        XCTAssertFalse(feed.isRunning)
        XCTAssertFalse(keepAlive.isActive)
    }
}

// MARK: - Dose reminders

final class RecordingNotificationCenter: DoseNotificationCentering {
    var authorized = true
    var requested: [DoseReminderRequest] = []
    var removedIdentifiers: [String] = []
    var removedAll = 0

    func requestAuthorization() async -> Bool { authorized }
    var failAdds = false
    func pendingIdentifiers() async -> [String] { requested.map(\.identifier) }
    func add(_ request: DoseReminderRequest) async throws {
        if failAdds { throw CocoaError(.fileWriteUnknown) }
        requested.removeAll { $0.identifier == request.identifier }
        requested.append(request)
    }
    func removePending(withIdentifiers ids: [String]) {
        removedIdentifiers += ids
        requested.removeAll { ids.contains($0.identifier) }
    }
    func removeDelivered(withIdentifiers ids: [String]) { deliveredRemovedIdentifiers += ids }
    var deliveredRemovedIdentifiers: [String] = []
    func removeAllPending() { removedAll += 1; requested.removeAll() }
}

private final class HeldReminderAdd: DoseNotificationCentering {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<Void, Never>?
    var pending: [DoseReminderRequest] = []
    var hold = true
    init(_ started: XCTestExpectation) { self.started = started }
    func requestAuthorization() async -> Bool { true }
    func pendingIdentifiers() async -> [String] { pending.map(\.identifier) }
    func add(_ request: DoseReminderRequest) async throws {
        if hold {
            hold = false
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(request)
    }
    func removePending(withIdentifiers ids: [String]) { pending.removeAll { ids.contains($0.identifier) } }
    func removeDelivered(withIdentifiers ids: [String]) {}
    func removeAllPending() { pending.removeAll() }
}

@MainActor
final class DoseReminderSchedulerTests: XCTestCase {
    func testMedicationsAtTheSameTimeHaveIndependentReminders() async {
        let center = RecordingNotificationCenter()
        let scheduler = DoseReminderScheduler(center: center)
        let first = MedicationSchedule(medicationName: "First", doseTimes: [DoseTime(hour: 8, minute: 0)])
        let second = MedicationSchedule(medicationName: "Second", doseTimes: first.doseTimes)
        await scheduler.sync([first, second])
        XCTAssertEqual(Set(center.requested.map(\.identifier)).count, 2)
        scheduler.doseTaken(at: first.doseDates(on: Date())[0], schedule: first)
        XCTAssertTrue(center.requested.contains { $0.title.contains("Second") && $0.repeatsDaily })
    }
    private var schedule: MedicationSchedule {
        MedicationSchedule(
            medicationName: "Levodopa",
            doseTimes: [DoseTime(hour: 8, minute: 0), DoseTime(hour: 12, minute: 30), DoseTime(hour: 17, minute: 30)]
        )
    }

    /// One repeating daily reminder per dose time, with the wearer's own
    /// medication name, in warm words.
    func testOneRepeatingReminderPerDoseTime() async {
        let center = RecordingNotificationCenter()
        let scheduler = DoseReminderScheduler(center: center)
        await scheduler.sync(schedule)

        XCTAssertEqual(center.removedAll, 0, "sync preserves other notification categories")
        XCTAssertEqual(center.requested.count, 3)
        let hours = center.requested.map(\.hour)
        XCTAssertEqual(hours, [8, 12, 17])
        XCTAssertEqual(center.requested[1].minute, 30)
        XCTAssertTrue(center.requested.allSatisfy(\.repeatsDaily))
        for request in center.requested {
            XCTAssertTrue(request.body.contains("Levodopa"))
            let lower = (request.title + " " + request.body).lowercased()
            XCTAssertFalse(lower.contains("missed"))
            XCTAssertFalse(lower.contains("overdue"))
            XCTAssertFalse(lower.contains("must"))
        }
        XCTAssertEqual(Set(center.requested.map(\.identifier)).count, 3, "identifiers are distinct")
    }

    func testResetDuringSystemAddCannotLeaveReminderBehind() async {
        let started = expectation(description: "System add started")
        let center = HeldReminderAdd(started)
        let scheduler = DoseReminderScheduler(center: center)
        let operation = Task { await scheduler.sync(schedule) }
        await fulfillment(of: [started], timeout: 2)
        scheduler.suspendForLocalReset()
        center.continuation?.resume()
        await operation.value
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(scheduler.status, .none)
    }

    func testNewPlanWinsWhenPreviousSystemAddFinishesLate() async {
        let started = expectation(description: "Old plan add started")
        let center = HeldReminderAdd(started)
        let scheduler = DoseReminderScheduler(center: center)
        let old = Task { await scheduler.sync(schedule) }
        await fulfillment(of: [started], timeout: 2)
        let replacement = MedicationSchedule(medicationName: "Replacement", doseTimes: [DoseTime(hour: 9, minute: 0)])
        let latest = Task { await scheduler.sync(replacement) }
        await Task.yield()
        center.continuation?.resume()
        await old.value; await latest.value
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertTrue(center.pending[0].title.contains("Replacement"))
        XCTAssertEqual(scheduler.status, .scheduled(1))
    }

    func testRejectedUpdatePreservesValidRemindersAndCanRetry() async {
        let center = RecordingNotificationCenter()
        let scheduler = DoseReminderScheduler(center: center)
        await scheduler.sync(schedule)
        let original = center.requested
        center.failAdds = true
        await scheduler.sync(schedule)
        XCTAssertEqual(scheduler.status, .failed)
        XCTAssertEqual(center.requested, original)
        center.failAdds = false
        await scheduler.sync(schedule)
        XCTAssertEqual(scheduler.status, .scheduled(3))
        XCTAssertEqual(center.requested.count, 3)
    }

    func testFailedPlanChangeStillRemovesObsoleteMedicationTimes() async {
        let center = RecordingNotificationCenter()
        let scheduler = DoseReminderScheduler(center: center)
        await scheduler.sync(schedule)
        center.failAdds = true
        await scheduler.sync(MedicationSchedule(medicationName: "New medicine", doseTimes: [DoseTime(hour: 9, minute: 0)]))
        XCTAssertEqual(scheduler.status, .failed)
        XCTAssertTrue(center.requested.isEmpty, "Removed medications must not continue reminding")
    }

    func testAnEmptyScheduleClearsEverything() async {
        let center = RecordingNotificationCenter()
        let scheduler = DoseReminderScheduler(center: center)
        await scheduler.sync(schedule)
        await scheduler.sync(MedicationSchedule(medicationName: "Levodopa", doseTimes: []))
        XCTAssertEqual(center.requested.count, 0)
    }

    func testWithoutPermissionNothingIsScheduledAndTheReasonIsKnown() async {
        let center = RecordingNotificationCenter()
        center.authorized = false
        let scheduler = DoseReminderScheduler(center: center)
        await scheduler.sync(schedule)
        XCTAssertEqual(center.requested.count, 0)
        XCTAssertEqual(scheduler.status, .notAllowed)
    }

    func testLoggingPreservesDailySeriesAndDismissesOnlyMatchingDeliveredReminder() async {
        let center = RecordingNotificationCenter()
        let scheduler = DoseReminderScheduler(center: center)
        await scheduler.sync(schedule)
        let before = center.requested
        let date = schedule.doseDates(on: Date())[0].addingTimeInterval(300)
        scheduler.doseTaken(at: date, schedule: schedule)
        scheduler.doseTaken(at: date, schedule: schedule)
        XCTAssertEqual(center.requested, before)
        XCTAssertTrue(center.removedIdentifiers.isEmpty)
        let id = DoseReminderScheduler.identifier(for: schedule.doseTimes[0], medication: schedule.medicationName)
        XCTAssertEqual(center.deliveredRemovedIdentifiers, [id, id])
        XCTAssertTrue(center.requested.allSatisfy { $0.repeatsDaily && $0.onDay == nil })
        // No dated one-off replaces the series: the same time-only trigger
        // remains eligible on tomorrow and every subsequent day without sync.
        for request in center.requested {
            var components = DateComponents(); components.hour = request.hour; components.minute = request.minute
            let tomorrow = Calendar.current.nextDate(after: date, matching: components, matchingPolicy: .nextTime)!
            let following = Calendar.current.nextDate(after: tomorrow, matching: components, matchingPolicy: .nextTime)!
            XCTAssertGreaterThan(following, tomorrow)
            XCTAssertEqual(Calendar.current.component(.hour, from: following), request.hour)
        }
    }

    func testEarlyDoseDoesNotCancelFutureRemindersAndCopyAsksToCheckRecords() async {
        let center = RecordingNotificationCenter()
        let scheduler = DoseReminderScheduler(center: center)
        await scheduler.sync(schedule)
        scheduler.doseTaken(at: schedule.doseDates(on: Date())[0].addingTimeInterval(-600), schedule: schedule)
        XCTAssertEqual(center.requested.count, schedule.doseTimes.count)
        XCTAssertTrue(center.requested.allSatisfy(\.repeatsDaily))
        XCTAssertTrue(center.requested.allSatisfy { $0.body.contains("dose record") && $0.body.contains("If unsure") })
    }
}
