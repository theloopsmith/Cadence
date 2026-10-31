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
    func add(_ request: DoseReminderRequest) { requested.append(request) }
    func removePending(withIdentifiers ids: [String]) {
        removedIdentifiers += ids
        requested.removeAll { ids.contains($0.identifier) }
    }
    func removeAllPending() { removedAll += 1; requested.removeAll() }
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

        XCTAssertEqual(center.removedAll, 1, "old reminders are cleared before new ones are set")
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

    /// Once today's dose is logged, today's reminder for it is withdrawn so
    /// the phone does not nag about a pill already taken.
    func testLoggingADoseWithdrawsTodaysReminderForIt() async {
        let center = RecordingNotificationCenter()
        let scheduler = DoseReminderScheduler(center: center)
        await scheduler.sync(schedule)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let s = MedicationSchedule(medicationName: "Levodopa", doseTimes: schedule.doseTimes, calendar: cal)
        let eightAM = cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 8, minute: 5))!

        scheduler.doseTaken(at: eightAM, schedule: s)

        XCTAssertEqual(center.removedIdentifiers.count, 1)
        XCTAssertTrue(center.removedIdentifiers[0].contains("08-00"))
        // Today's daily reminder is gone; a one-off covers tomorrow. A
        // repeating trigger cannot start in the future, so the daily series
        // returns on the next sync, which runs at launch and on any change.
        let eights = center.requested.filter { $0.hour == 8 }
        XCTAssertEqual(eights.count, 1)
        XCTAssertFalse(eights[0].repeatsDaily)
        XCTAssertEqual(eights[0].onDay?.day, 16)
        XCTAssertEqual(center.requested.count, 3, "the other dose times are untouched")

        await scheduler.sync(s)
        XCTAssertEqual(center.requested.filter { $0.hour == 8 && $0.repeatsDaily }.count, 1)
    }
}
