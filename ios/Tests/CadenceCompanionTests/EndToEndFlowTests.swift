import XCTest
@testable import CadenceCompanion

/// Drives the two wired flows the way the companion view drives them, so the
/// sequencing is covered even though the Simulator is unavailable on this
/// machine (xcode-select points at the Command Line Tools).
@MainActor
final class EndToEndFlowTests: XCTestCase {
    private var dbPath: String!
    private var sync: EventSyncManager!
    private var screen: NoopScreenController!
    private var dialer: RecordingPhoneDialer!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "cadence-e2e-\(UUID().uuidString).sqlite"
        sync = EventSyncManager(
            transport: StubTransport(), databasePath: dbPath, startPeriodicDrain: false
        )
        screen = NoopScreenController()
        dialer = RecordingPhoneDialer()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: dbPath)
        AudioCueEngine.shared.deactivateBystanderSiren()
        try await super.tearDown()
    }

    /// The full fall path the demo button drives: three IMU samples through the
    /// state machine, the returned UUID handed to the coordinator, silence,
    /// escalation, and finally a cancel that reaches the backend.
    func testFallDetectionThroughEscalationToCancel() {
        let detector = FallDetector()
        let coordinator = FallAlertCoordinator(
            detector: detector, audio: .shared, screen: screen, dialer: dialer, sync: sync
        )
        coordinator.caregiverPhoneNumber = "+15550102030"

        // Stage 1 free-fall, Stage 2 impact, Stage 3 stillness.
        XCTAssertNil(detector.processIMUSample(
            IMUSample(timestamp: 1.00, ax: 0.1, ay: 0.1, az: 0.1,
                      gx: 0, gy: 0, gz: 0, pitchDeg: 4.0, rollDeg: 2.0)
        ))
        XCTAssertNil(detector.processIMUSample(
            IMUSample(timestamp: 1.10, ax: 0.2, ay: 3.85, az: 0.3,
                      gx: 3, gy: 2, gz: 1, pitchDeg: 25.0, rollDeg: 10.0)
        ))
        let eventUUID = detector.processIMUSample(
            IMUSample(timestamp: 1.80, ax: 0.98, ay: 0.15, az: 0.05,
                      gx: 0.01, gy: 0.01, gz: 0.01, pitchDeg: 76.0, rollDeg: 4.0),
            latitude: 37.7749, longitude: -122.4194, horizontalAccuracyM: 6.5
        )
        XCTAssertNotNil(eventUUID, "Stage 3 must confirm and return an event id")

        // The view hands the detector's own id to the coordinator, so the
        // locally saved row and the escalation share one identifier.
        coordinator.beginCheckIn(eventUUID: eventUUID!)
        XCTAssertTrue(coordinator.isAlertVisible)
        XCTAssertFalse(coordinator.isDispatched, "check-in is calm, not alarming")
        XCTAssertTrue(screen.isEmergencyBrightnessEngaged)

        // No response: escalate.
        let outcome = coordinator.resolveFromSpeech(
            transcript: nil, maxVocalLevelDbfs: -55.0, hardwareWearStateWorn: true,
            preImpactWearRmsG: 0.08, preImpactRespPower: 2.0e-5, preImpactPitchDeg: 5.0
        )
        XCTAssertEqual(outcome, "confirmed_waiting_dispatch")
        XCTAssertTrue(coordinator.isDispatched, "beacon must now flash")
        XCTAssertTrue(AudioCueEngine.shared.isSirenActive)
        XCTAssertEqual(coordinator.activeEventUUID, eventUUID)

        // A bystander taps the caregiver button, then cancels.
        coordinator.callCaregiver()
        XCTAssertEqual(dialer.dialedNumbers, ["+15550102030"])

        coordinator.cancelByUser()
        XCTAssertFalse(coordinator.isAlertVisible)
        XCTAssertFalse(AudioCueEngine.shared.isSirenActive)
        XCTAssertFalse(screen.isEmergencyBrightnessEngaged)
        XCTAssertFalse(screen.isIdleTimerDisabled)

        let endpoints = sync.dueEvents().map(\.endpoint)
        XCTAssertTrue(
            endpoints.contains("/api/v1/events/fall/\(eventUUID!)/cancel"),
            "cancel must reach the backend so retries stop: \(endpoints)"
        )
    }

    /// The other demo route: the wearer answers and nothing escalates.
    func testFallResolvedBySpeechNeverSoundsTheSiren() {
        let detector = FallDetector()
        let coordinator = FallAlertCoordinator(
            detector: detector, audio: .shared, screen: screen, dialer: dialer, sync: sync
        )
        coordinator.beginCheckIn(eventUUID: "fall-spoken-1")

        let outcome = coordinator.resolveFromSpeech(
            transcript: "I'm okay, just dropped my keys", maxVocalLevelDbfs: -22.0,
            hardwareWearStateWorn: true, preImpactWearRmsG: 0.08,
            preImpactRespPower: 2.0e-5, preImpactPitchDeg: 8.0
        )
        XCTAssertEqual(outcome, "canceled_false_alarm")
        XCTAssertFalse(AudioCueEngine.shared.isSirenActive, "a resolved check-in never sounds")
        XCTAssertTrue(dialer.dialedNumbers.isEmpty, "nobody should be called")
    }

    /// The exam button's full path: three prompts, submit, raw measurements on screen.
    func testGuidedExamRunsAndShowsMeasurementsNotAScore() async {
        let scored = HomeMotorExamResult(
            examUUID: "exam-e2e-1", medicationStateLabel: "WEARING_OFF",
            voiceScore: 86.5, handwritingScore: 72.8, gaitScore: 71.5,
            compositeMotorScore: 76.4, clinicalSummary: "composite 76.4"
        )
        let stub = StubExamSubmitter(result: scored)
        let mgr = HomeMotorExamManager(submitter: stub, audio: .shared, sync: sync)
        mgr.stepPauseSec = 0

        var m = HomeMotorExamMeasurements()
        m.voiceMeanDbfs = -26.5
        m.voiceStabilityDb = 2.9
        m.handwritingOpencvDecayPct = -22.0
        m.handwritingSamDecayPct = -20.5
        m.walkCadenceSpm = 88.0
        m.walkMeanFI = 1.65

        let summary = await mgr.runDemoExam(measurements: m, examUUID: "exam-e2e-1")
        XCTAssertEqual(mgr.currentStep, .completed)
        XCTAssertEqual(mgr.lastResult?.compositeMotorScore, 76.4)
        XCTAssertFalse(summary.contains("WEARING_OFF"))
        XCTAssertTrue(summary.contains("22% smaller"), summary)
        XCTAssertEqual(sync.pendingCount(), 0, "a successful exam must not be queued for retry")
    }
}
