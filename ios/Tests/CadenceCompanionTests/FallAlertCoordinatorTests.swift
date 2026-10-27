import XCTest
@testable import CadenceCompanion

@MainActor
final class FallAlertCoordinatorTests: XCTestCase {
    private var screen: NoopScreenController!
    private var dialer: RecordingPhoneDialer!
    private var sync: EventSyncManager!
    private var dbPath: String!

    override func setUp() async throws {
        try await super.setUp()
        screen = NoopScreenController()
        dialer = RecordingPhoneDialer()
        dbPath = NSTemporaryDirectory() + "cadence-alert-\(UUID().uuidString).sqlite"
        sync = EventSyncManager(
            transport: StubTransport(), databasePath: dbPath, startPeriodicDrain: false
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: dbPath)
        AudioCueEngine.shared.deactivateBystanderSiren()
        try await super.tearDown()
    }

    private func makeCoordinator() -> FallAlertCoordinator {
        FallAlertCoordinator(
            detector: FallDetector(), audio: .shared,
            screen: screen, dialer: dialer, sync: sync
        )
    }

    /// The check-in screen appears immediately and brings the display up, so a
    /// wearer on the floor can find the cancel button.
    func testCheckInRaisesBrightnessAndKeepsScreenAwake() {
        let c = makeCoordinator()
        XCTAssertFalse(c.isAlertVisible)

        c.beginCheckIn(eventUUID: "fall-1")
        XCTAssertTrue(c.isAlertVisible)
        XCTAssertTrue(screen.isEmergencyBrightnessEngaged)
        XCTAssertTrue(screen.isIdleTimerDisabled)
    }

    /// During check-in the wearer is being asked a question, not alarmed: the
    /// siren and the flashing beacon belong to the dispatched phase only.
    func testCheckInDoesNotYetFlashOrSoundTheSiren() {
        let c = makeCoordinator()
        c.beginCheckIn(eventUUID: "fall-2")
        XCTAssertFalse(c.isDispatched, "check-in must not flash the beacon")
        XCTAssertFalse(AudioCueEngine.shared.isSirenActive)
    }

    /// Silence past the window escalates: siren on, beacon flashing, event queued.
    func testSilentTimeoutEscalatesAndQueuesTheEvent() {
        let c = makeCoordinator()
        c.beginCheckIn(eventUUID: "fall-3")
        let outcome = c.resolveFromSpeech(
            transcript: nil, maxVocalLevelDbfs: -55.0,
            hardwareWearStateWorn: true, preImpactWearRmsG: 0.08,
            preImpactRespPower: 2.0e-5, preImpactPitchDeg: 5.0
        )
        XCTAssertEqual(outcome, "confirmed_waiting_dispatch")
        XCTAssertTrue(c.isDispatched)
        XCTAssertTrue(AudioCueEngine.shared.isSirenActive)
        XCTAssertEqual(sync.pendingCount(), 1, "the fall must be queued for the backend")
    }

    /// A recognized affirmative phrase cancels without ever contacting anyone.
    func testSpokenCancellationStandsDownAndRestoresTheScreen() {
        let c = makeCoordinator()
        c.beginCheckIn(eventUUID: "fall-4")
        let outcome = c.resolveFromSpeech(
            transcript: "I'm okay, just sat down hard", maxVocalLevelDbfs: -20.0,
            hardwareWearStateWorn: true, preImpactWearRmsG: 0.08,
            preImpactRespPower: 2.0e-5, preImpactPitchDeg: 5.0
        )
        XCTAssertEqual(outcome, "canceled_false_alarm")
        XCTAssertFalse(c.isAlertVisible)
        XCTAssertFalse(AudioCueEngine.shared.isSirenActive)
        XCTAssertFalse(screen.isEmergencyBrightnessEngaged, "brightness must be given back")
        XCTAssertFalse(screen.isIdleTimerDisabled)
    }

    /// Tapping cancel is its own cancellation route, not a synthesized
    /// transcript. The view used to fake "I'm okay" on every tap, which meant
    /// a button press was evaluated by the phrase matcher that exists to judge
    /// speech.
    func testButtonCancelDuringCheckInRecordsAFalseAlarm() {
        let c = makeCoordinator()
        c.beginCheckIn(eventUUID: "fall-5")
        c.cancelByUser()

        XCTAssertFalse(c.isAlertVisible)
        XCTAssertEqual(c.lastOutcome, "canceled_by_user_button")
        XCTAssertEqual(sync.pendingCount(), 1, "a resolved candidate is still recorded")
    }

    /// Cancelling after escalation must reach the backend's cancel endpoint so
    /// the retry loop halts and the All-Clear SMS goes out.
    func testButtonCancelAfterDispatchCallsTheCancelEndpoint() async {
        let c = makeCoordinator()
        c.beginCheckIn(eventUUID: "fall-6")
        c.escalate(peakImpactG: 3.9, peakJerkGs: 48.0, postImpactTiltDeg: 72.0)
        XCTAssertTrue(c.isDispatched)

        c.cancelByUser()
        XCTAssertFalse(c.isAlertVisible)
        XCTAssertFalse(AudioCueEngine.shared.isSirenActive)

        let queued = sync.dueEvents()
        XCTAssertTrue(
            queued.contains { $0.endpoint == "/api/v1/events/fall/fall-6/cancel" },
            "post-dispatch cancel must hit the cancel endpoint, got \(queued.map(\.endpoint))"
        )
    }

    /// GPS travels with the escalated event so the caregiver SMS can carry a
    /// map link.
    func testEscalationCarriesGPSIntoTheQueuedPayload() {
        let c = makeCoordinator()
        c.beginCheckIn(eventUUID: "fall-7")
        c.escalate(
            peakImpactG: 3.4, peakJerkGs: 41.0, postImpactTiltDeg: 68.0,
            latitude: 37.7749, longitude: -122.4194, horizontalAccuracyM: 5.0
        )
        let payload = sync.dueEvents().first { $0.eventUUID == "fall-7" }?.payloadJSON ?? ""
        XCTAssertTrue(payload.contains("37.7749"), "latitude missing from payload")
        XCTAssertTrue(payload.contains("-122.4194"), "longitude missing from payload")
    }

    /// iOS cannot auto-dial, so the SOS screen offers tap targets. Both must
    /// reach the right number.
    func testOneTapDialingUsesCaregiverThenFallsBackToEmergency() {
        let c = makeCoordinator()
        c.caregiverPhoneNumber = "+1 (555) 010-2030"
        c.callCaregiver()
        XCTAssertEqual(dialer.dialedNumbers, ["+1 (555) 010-2030"])
        XCTAssertEqual(c.caregiverButtonTitle, "CALL CAREGIVER")

        c.callEmergencyServices()
        XCTAssertEqual(dialer.dialedNumbers.last, "911")
    }

    func testWithoutACaregiverNumberTheButtonOffersEmergencyServices() {
        let c = makeCoordinator()
        c.caregiverPhoneNumber = nil
        XCTAssertEqual(c.caregiverButtonTitle, "CALL 911")
        c.callCaregiver()
        XCTAssertEqual(dialer.dialedNumbers, ["911"])
    }

    /// A suppressed unworn drop must stand the alert down quietly rather than
    /// escalating or leaving the screen pinned bright.
    func testSuppressedUnwornDropStandsDownWithoutSiren() {
        let detector = FallDetector()
        detector.enableUnwornDropSuppression = true
        let coordinator = FallAlertCoordinator(
            detector: detector, audio: .shared, screen: screen, dialer: dialer, sync: sync
        )
        coordinator.beginCheckIn(eventUUID: "fall-8")
        let outcome = coordinator.resolveFromSpeech(
            transcript: nil, maxVocalLevelDbfs: -60.0,
            hardwareWearStateWorn: false, preImpactWearRmsG: 0.001,
            preImpactRespPower: 0.0, preImpactPitchDeg: 0.0
        )
        XCTAssertEqual(outcome, "suppressed_unworn_drop")
        XCTAssertFalse(coordinator.isAlertVisible)
        XCTAssertFalse(AudioCueEngine.shared.isSirenActive)
        XCTAssertFalse(screen.isEmergencyBrightnessEngaged)
    }

    // MARK: - The 12-second window runs on its own

    private func makeCoordinator(checkInWindow: TimeInterval) -> FallAlertCoordinator {
        FallAlertCoordinator(
            detector: FallDetector(), audio: .shared,
            screen: screen, dialer: dialer, sync: sync,
            checkInWindow: checkInWindow
        )
    }

    /// A wearer who is unconscious cannot press a button or speak. The
    /// coordinator stored a deadline but nothing ever acted on it, so silence
    /// escalated only when the demo's "Silent Timeout" button was pressed.
    func testSilenceThroughTheCheckInWindowEscalatesWithoutAnyInput() async throws {
        let c = makeCoordinator(checkInWindow: 0.05)
        c.beginCheckIn(eventUUID: "fall-timeout-1")
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(c.isDispatched, "silence past the window must escalate by itself")
        XCTAssertEqual(c.lastOutcome, "confirmed_waiting_dispatch")
        XCTAssertTrue(AudioCueEngine.shared.isSirenActive)
        XCTAssertEqual(sync.pendingCount(), 1, "the escalation must be queued for the backend")
    }

    func testAnsweringInsideTheWindowStopsTheTimer() async throws {
        let c = makeCoordinator(checkInWindow: 0.15)
        c.beginCheckIn(eventUUID: "fall-timeout-2")
        c.resolveFromSpeech(
            transcript: "I'm okay", maxVocalLevelDbfs: -20.0,
            hardwareWearStateWorn: true, preImpactWearRmsG: 0.08,
            preImpactRespPower: 2.0e-5, preImpactPitchDeg: 5.0
        )
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertFalse(c.isAlertVisible)
        XCTAssertEqual(c.lastOutcome, "canceled_false_alarm", "a stale timer must not re-escalate")
        XCTAssertFalse(AudioCueEngine.shared.isSirenActive)
    }

    func testANewCheckInReplacesTheTimerOfThePreviousOne() async throws {
        let c = makeCoordinator(checkInWindow: 0.15)
        c.beginCheckIn(eventUUID: "fall-timeout-3a")
        c.cancelByUser()
        c.beginCheckIn(eventUUID: "fall-timeout-3b")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(c.isDispatched, "the first alert's timer must not escalate the second")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(c.activeEventUUID, "fall-timeout-3b")
        XCTAssertTrue(c.isDispatched)
    }

    /// The view ran its own `FallDetector` while the coordinator resolved the
    /// check-in on a second instance, so the detector that saw the fall stayed
    /// in its check-in stage forever and could never report another one.
    func testTheDetectorThatSawTheFallIsReadyForTheNextOne() async throws {
        let c = makeCoordinator(checkInWindow: 0.05)

        let first = Self.driveHardFall(c.detector, startingAt: 1.0)
        XCTAssertNotNil(first)
        c.beginCheckIn(eventUUID: first!)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(c.isDispatched)
        c.cancelByUser()

        let second = Self.driveHardFall(c.detector, startingAt: 60.0)
        XCTAssertNotNil(second, "a second fall must still be detected")
    }

    /// Stage 1 free-fall, Stage 2 impact, Stage 3 stillness.
    private static func driveHardFall(_ detector: FallDetector, startingAt t: Double) -> String? {
        _ = detector.processIMUSample(
            IMUSample(timestamp: t, ax: 0.1, ay: 0.1, az: 0.1,
                      gx: 0, gy: 0, gz: 0, pitchDeg: 4.0, rollDeg: 2.0)
        )
        _ = detector.processIMUSample(
            IMUSample(timestamp: t + 0.10, ax: 0.2, ay: 3.85, az: 0.3,
                      gx: 3, gy: 2, gz: 1, pitchDeg: 25.0, rollDeg: 10.0)
        )
        return detector.processIMUSample(
            IMUSample(timestamp: t + 0.80, ax: 0.98, ay: 0.15, az: 0.05,
                      gx: 0.01, gy: 0.01, gz: 0.01, pitchDeg: 76.0, rollDeg: 4.0)
        )
    }

    /// Escalating only makes sense from an open check-in; a stray call must not
    /// start a siren out of nowhere.
    func testEscalateIsIgnoredWhenNoCheckInIsOpen() {
        let c = makeCoordinator()
        c.escalate()
        XCTAssertFalse(c.isDispatched)
        XCTAssertFalse(AudioCueEngine.shared.isSirenActive)
    }
}
