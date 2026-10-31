import XCTest
@testable import CadenceCompanion

// MARK: - Tap guard

final class TapGuardTests: XCTestCase {
    /// A trembling finger taps twice. Only the first lands.
    func testASecondTapWithinTheWindowIsIgnored() {
        var fired = 0
        let guardRail = TapGuard(windowSec: 0.6)
        let t0 = Date(timeIntervalSince1970: 1_000)
        guardRail.perform(at: t0) { fired += 1 }
        guardRail.perform(at: t0.addingTimeInterval(0.2)) { fired += 1 }
        guardRail.perform(at: t0.addingTimeInterval(0.55)) { fired += 1 }
        XCTAssertEqual(fired, 1)
        guardRail.perform(at: t0.addingTimeInterval(0.7)) { fired += 1 }
        XCTAssertEqual(fired, 2)
    }

    func testEachGuardIsIndependent() {
        var a = 0, b = 0
        let ga = TapGuard(windowSec: 0.6), gb = TapGuard(windowSec: 0.6)
        let t = Date()
        ga.perform(at: t) { a += 1 }
        gb.perform(at: t) { b += 1 }
        XCTAssertEqual(a + b, 2)
    }
}

// MARK: - Medication schedule

final class MedicationScheduleTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 15) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = day; c.hour = hour; c.minute = minute
        c.timeZone = TimeZone(identifier: "UTC")
        return calendar.date(from: c)!
    }

    private var schedule: MedicationSchedule {
        var cal = calendar
        cal.timeZone = TimeZone(identifier: "UTC")!
        return MedicationSchedule(
            medicationName: "Levodopa",
            doseTimes: [
                DoseTime(hour: 8, minute: 0),
                DoseTime(hour: 12, minute: 30),
                DoseTime(hour: 17, minute: 30),
            ],
            calendar: cal
        )
    }

    func testNextDoseIsTheFirstUpcomingTimeToday() {
        XCTAssertEqual(schedule.nextDose(after: at(7, 15)), at(8, 0))
        XCTAssertEqual(schedule.nextDose(after: at(8, 0)), at(12, 30))
        XCTAssertEqual(schedule.nextDose(after: at(13, 0)), at(17, 30))
    }

    func testAfterTheLastDoseTheNextIsTomorrowMorning() {
        XCTAssertEqual(schedule.nextDose(after: at(18, 0)), at(8, 0, day: 16))
    }

    /// A dose is "due" from 30 minutes before its time until it is taken or
    /// the next one comes round.
    func testDueWindowOpensThirtyMinutesEarly() {
        XCTAssertFalse(schedule.isDoseDue(at: at(7, 29), takenToday: []))
        XCTAssertTrue(schedule.isDoseDue(at: at(7, 31), takenToday: []))
        XCTAssertTrue(schedule.isDoseDue(at: at(9, 0), takenToday: []), "late is still due, without blame")
        XCTAssertFalse(schedule.isDoseDue(at: at(9, 0), takenToday: [at(8, 5)]))
    }

    /// Off windows: the half hour before each dose, and anything more than
    /// three hours after the last dose taken. Predicted from the schedule
    /// alone when nothing has been logged.
    func testOffWindowsBracketEachDose() {
        XCTAssertTrue(schedule.isPredictedOffPeriod(at: at(7, 45), lastDoseTaken: at(4, 0)))
        XCTAssertFalse(schedule.isPredictedOffPeriod(at: at(9, 0), lastDoseTaken: at(8, 0)))
        XCTAssertTrue(schedule.isPredictedOffPeriod(at: at(11, 30), lastDoseTaken: at(8, 0)), "3.5 h after a dose")
        XCTAssertTrue(schedule.isPredictedOffPeriod(at: at(12, 10), lastDoseTaken: at(8, 0)))
        XCTAssertFalse(schedule.isPredictedOffPeriod(at: at(14, 0), lastDoseTaken: at(12, 30)))
    }

    func testWithNoDoseLoggedTheMorningBeforeTheFirstDoseIsOff() {
        XCTAssertTrue(schedule.isPredictedOffPeriod(at: at(6, 0), lastDoseTaken: nil))
    }

    func testEmptyScheduleNeverPredictsAnOffPeriodOrADose() {
        let empty = MedicationSchedule(medicationName: "Levodopa", doseTimes: [], calendar: calendar)
        XCTAssertNil(empty.nextDose(after: at(8, 0)))
        XCTAssertFalse(empty.isDoseDue(at: at(8, 0), takenToday: []))
        XCTAssertFalse(empty.isPredictedOffPeriod(at: at(8, 0), lastDoseTaken: nil))
    }

    func testScheduleRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(schedule)
        let decoded = try JSONDecoder().decode(MedicationSchedule.self, from: data)
        XCTAssertEqual(decoded.doseTimes, schedule.doseTimes)
        XCTAssertEqual(decoded.medicationName, "Levodopa")
    }
}

// MARK: - Diary

final class DiaryStoreTests: XCTestCase {
    private func tempStore() -> DiaryStore {
        DiaryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diary-\(UUID().uuidString)"))
    }

    func testEventsAreAppendedAndReadBackNewestFirst() throws {
        let store = tempStore()
        let noon = Date(timeIntervalSince1970: 1_780_000_000)
        try store.append(DiaryEvent(kind: .cue, at: noon, detail: "Beat played for 4 seconds"))
        try store.append(DiaryEvent(kind: .doseTaken, at: noon.addingTimeInterval(60), detail: "Levodopa"))
        let events = try store.events(on: noon)
        XCTAssertEqual(events.map(\.kind), [.doseTaken, .cue])
    }

    func testPlainFactsCompareTodayWithYesterday() throws {
        let store = tempStore()
        let today = Date(timeIntervalSince1970: 1_780_000_000)
        let yesterday = today.addingTimeInterval(-86_400)
        for _ in 0..<3 { try store.append(DiaryEvent(kind: .cue, at: today, detail: "")) }
        for _ in 0..<5 { try store.append(DiaryEvent(kind: .cue, at: yesterday, detail: "")) }
        try store.append(DiaryEvent(kind: .checkInAnswered, at: today, detail: "Said I'm okay"))

        let facts = try store.plainFacts(for: today)
        XCTAssertTrue(facts.contains("3 freezes today, 5 yesterday"), facts.joined(separator: " | "))
        XCTAssertTrue(facts.contains("1 check-in answered today"), facts.joined(separator: " | "))
        XCTAssertFalse(facts.joined().lowercased().contains("score"))
    }

    func testAnEventCanBeRemovedForUndo() throws {
        let store = tempStore()
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let event = DiaryEvent(kind: .doseTaken, at: now, detail: "Levodopa")
        try store.append(event)
        XCTAssertEqual(try store.events(on: now).count, 1)
        try store.remove(id: event.id)
        XCTAssertEqual(try store.events(on: now).count, 0)
    }

    func testEveryKindHasAnIconAndAWord() {
        for kind in DiaryEventKind.allCases {
            XCTAssertFalse(kind.systemImage.isEmpty)
            XCTAssertFalse(kind.word.isEmpty)
        }
    }
}

// MARK: - Dose logging

@MainActor
final class DoseLogModelTests: XCTestCase {
    private func makeModel(transport: RecordingJSONTransport = RecordingJSONTransport(), now: Date) -> (DoseLogModel, DiaryStore, EventSyncManager) {
        let diary = DiaryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dose-\(UUID().uuidString)"))
        let sync = EventSyncManager(
            databasePath: NSTemporaryDirectory() + "dose-\(UUID().uuidString).sqlite",
            startPeriodicDrain: false
        )
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let schedule = MedicationSchedule(
            medicationName: "Levodopa",
            doseTimes: [DoseTime(hour: 8, minute: 0), DoseTime(hour: 12, minute: 30)],
            calendar: cal
        )
        let model = DoseLogModel(schedule: schedule, diary: diary, sync: sync, clock: { now })
        return (model, diary, sync)
    }

    private func utc(_ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 15; c.hour = hour; c.minute = minute
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    /// Taken: queued for the backend, written to the diary, and undoable
    /// for as long as the card is on screen. No vanishing toast.
    func testTakenQueuesLogsAndOffersUndo() throws {
        let (model, diary, sync) = makeModel(now: utc(8, 5))
        XCTAssertTrue(model.isDoseDue)
        XCTAssertTrue(model.headline.contains("8:00"))

        model.markTaken()

        XCTAssertFalse(model.isDoseDue)
        XCTAssertTrue(model.canUndo)
        XCTAssertEqual(sync.pendingCount(), 1)
        XCTAssertEqual(try diary.events(on: utc(8, 5)).first?.kind, .doseTaken)
        XCTAssertTrue(model.headline.lowercased().contains("logged"))

        model.undo()

        XCTAssertTrue(model.isDoseDue)
        XCTAssertFalse(model.canUndo)
        XCTAssertEqual(try diary.events(on: utc(8, 5)).count, 0)
        XCTAssertEqual(sync.pendingCount(), 0, "the queued dose must be withdrawn too")
    }

    /// Late is fine. The copy never scolds.
    func testALateDoseIsWordedWithoutBlame() {
        let (model, _, _) = makeModel(now: utc(10, 0))
        XCTAssertTrue(model.isDoseDue)
        let text = (model.headline + " " + model.detail).lowercased()
        XCTAssertFalse(text.contains("missed"))
        XCTAssertFalse(text.contains("overdue"))
        XCTAssertFalse(text.contains("late"))
        XCTAssertTrue(text.contains("when you can") || text.contains("ready"))
    }

    func testBetweenDosesTheCardShowsTheNextTime() {
        let (model, _, _) = makeModel(now: utc(9, 0))
        model.markTaken()
        XCTAssertFalse(model.isDoseDue)
        XCTAssertTrue(model.detail.contains("12:30"))
    }

    func testSimpleModeFollowsThePredictedOffWindow() {
        let (before, _, _) = makeModel(now: utc(7, 45))
        XCTAssertTrue(before.isSimpleMode, "the half hour before a dose is an off window")
        let (after, _, _) = makeModel(now: utc(9, 0))
        after.markTaken()
        XCTAssertFalse(after.isSimpleMode)
    }
}

// MARK: - Check-in window

@MainActor
final class CheckInWindowTests: XCTestCase {
    func testTheCheckInGivesAtLeastThirtySeconds() {
        XCTAssertGreaterThanOrEqual(FallAlertCoordinator.checkInWindowSec, 30)
    }

    func testAnsweringLateInTheWindowStillCancels() async {
        let sync = EventSyncManager(
            databasePath: NSTemporaryDirectory() + "late-\(UUID().uuidString).sqlite",
            startPeriodicDrain: false
        )
        let c = FallAlertCoordinator(
            screen: NoopScreenController(), dialer: RecordingPhoneDialer(), sync: sync,
            locationProvider: MockLocationProvider(), speechListener: MockSpeechCheckInListener(),
            checkInWindow: 0.3
        )
        c.beginCheckIn(eventUUID: "late-answer")
        try? await Task.sleep(nanoseconds: 200_000_000)
        c.cancelByUser()
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(c.isDispatched)
        XCTAssertEqual(c.lastOutcome, "canceled_by_user_button")
    }
}

// MARK: - Motor Check State Machine

@MainActor
final class MotorExamInteractionTests: XCTestCase {
    func testCancellingExamResetsStepToIdle() {
        let manager = HomeMotorExamManager()
        manager.startExam()
        XCTAssertEqual(manager.currentStep, .task1PromptedVoice)
        manager.cancelExam()
        XCTAssertEqual(manager.currentStep, .idle)
    }

    func testAdvancingThroughTasksCollectsSteps() {
        let manager = HomeMotorExamManager()
        manager.startExam()
        XCTAssertEqual(manager.currentStep, .task1PromptedVoice)
        manager.advanceToHandwriting()
        XCTAssertEqual(manager.currentStep, .task2PromptedHandwriting)
        manager.advanceToTimedWalk()
        XCTAssertEqual(manager.currentStep, .task3PromptedTimedWalk)
        manager.cancelExam()
        XCTAssertEqual(manager.currentStep, .idle)
    }

    func testAppModelForwardsExamObjectWillChange() {
        let app = CadenceAppModel()
        var appChanged = false
        let cancellable = app.objectWillChange.sink { _ in appChanged = true }
        app.exam.startExam()
        XCTAssertTrue(appChanged, "app.objectWillChange must fire when exam state changes")
        cancellable.cancel()
    }
}

// MARK: - Clinical Report Presentation

@MainActor
final class DaySummaryPresentationTests: XCTestCase {
    func testDaySummaryViewInitializesWithApp() {
        let app = CadenceAppModel()
        let reportView = DaySummaryView(app: app)
        XCTAssertNotNil(reportView)
    }
}

@MainActor
final class MedicationTabPresentationTests: XCTestCase {
    func testMedicationSetupViewInitializesAsTab() {
        let app = CadenceAppModel()
        let tabView = MedicationSetupView(app: app, isTab: true)
        XCTAssertTrue(tabView.isTab)
    }

    func testCadenceRootViewInitializes() {
        let rootView = CadenceRootView()
        XCTAssertNotNil(rootView)
    }
}
