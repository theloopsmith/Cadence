import XCTest
@testable import CadenceCompanion

/// Captures the submitted body and returns a canned result, so the exam flow
/// is tested without a backend.
final class StubExamSubmitter: ExamSubmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var _bodies: [Data] = []
    private let result: HomeMotorExamResult?

    init(result: HomeMotorExamResult?) { self.result = result }

    var submittedBodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return _bodies
    }

    var submittedJSON: [[String: Any]] {
        submittedBodies.compactMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
    }

    func submit(examJSON: Data, bearerToken: String) async -> HomeMotorExamResult? {
        record(examJSON)
        return result
    }

    /// Non-async so NSLock is never held across a suspension point.
    private func record(_ body: Data) {
        lock.lock(); defer { lock.unlock() }
        _bodies.append(body)
    }
}

/// Mirrors a real `POST /api/v1/exam/complete` response, verified against the
/// live endpoint for these exact measurements.
private let scoredResult = HomeMotorExamResult(
    examUUID: "exam-test-1",
    medicationStateLabel: "WEARING_OFF",
    voiceScore: 86.5,
    handwritingScore: 72.8,
    gaitScore: 71.5,
    compositeMotorScore: 76.4,
    clinicalSummary: "Guided Home Motor Exam (WEARING_OFF): Composite 76.4/100."
)

extension HomeMotorExamResult {
    init(
        examUUID: String, medicationStateLabel: String, voiceScore: Double,
        handwritingScore: Double, gaitScore: Double, compositeMotorScore: Double,
        clinicalSummary: String
    ) {
        let json: [String: Any] = [
            "exam_uuid": examUUID,
            "medication_state_label": medicationStateLabel,
            "voice_score": voiceScore,
            "handwriting_score": handwritingScore,
            "gait_score": gaitScore,
            "composite_motor_score": compositeMotorScore,
            "clinical_summary": clinicalSummary,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        self = try! JSONDecoder().decode(HomeMotorExamResult.self, from: data)
    }
}

@MainActor
final class HomeMotorExamTests: XCTestCase {
    private var dbPath: String!
    private var sync: EventSyncManager!

    override func setUp() async throws {
        try await super.setUp()
        dbPath = NSTemporaryDirectory() + "cadence-exam-\(UUID().uuidString).sqlite"
        sync = EventSyncManager(
            transport: StubTransport(), databasePath: dbPath, startPeriodicDrain: false
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: dbPath)
        try await super.tearDown()
    }

    private func measurements() -> HomeMotorExamMeasurements {
        var m = HomeMotorExamMeasurements()
        m.voiceMeanDbfs = -26.5
        m.voiceStabilityDb = 2.9
        m.handwritingOpencvDecayPct = -22.0
        m.handwritingSamDecayPct = -20.5
        m.walkCadenceSpm = 88.0
        m.walkMeanFI = 1.65
        m.walkFogCount = 0
        return m
    }

    /// The three prompts run in order and the manager reports which step the
    /// wearer is on.
    func testExamWalksThroughAllThreeStepsInOrder() async {
        let mgr = HomeMotorExamManager(
            submitter: StubExamSubmitter(result: scoredResult), audio: .shared, sync: sync
        )
        XCTAssertEqual(mgr.currentStep, .idle)
        XCTAssertNil(mgr.currentPrompt)

        mgr.startExam()
        XCTAssertEqual(mgr.currentStep, .task1PromptedVoice)
        XCTAssertTrue(mgr.currentPrompt?.contains("Ahhh") == true)
        XCTAssertTrue(mgr.isRunning)

        mgr.advanceToHandwriting()
        XCTAssertEqual(mgr.currentStep, .task2PromptedHandwriting)
        XCTAssertTrue(mgr.currentPrompt?.contains("Write") == true)

        mgr.advanceToTimedWalk()
        XCTAssertEqual(mgr.currentStep, .task3PromptedTimedWalk)
        XCTAssertTrue(mgr.currentPrompt?.contains("walk forward") == true)

        _ = await mgr.completeExam(examUUID: "exam-steps-1")
        XCTAssertEqual(mgr.currentStep, .completed)
        XCTAssertFalse(mgr.isRunning)
    }

    /// The submitted body must carry every field the backend's Pydantic model
    /// requires, under the exact snake_case names it expects.
    func testSubmittedPayloadMatchesTheBackendContract() async {
        let stub = StubExamSubmitter(result: scoredResult)
        let mgr = HomeMotorExamManager(submitter: stub, audio: .shared, sync: sync)
        var valid = measurements()
        valid.voiceMeasured = true; valid.handwritingMeasured = true; valid.walkMeasured = true
        mgr.measurements = valid

        _ = await mgr.completeExam(examUUID: "exam-contract-1")

        XCTAssertEqual(stub.submittedJSON.count, 1)
        let body = stub.submittedJSON[0]
        for key in [
            "exam_uuid", "timestamp_utc", "voice_mean_dbfs", "voice_stability_db",
            "handwriting_opencv_decay_pct", "walk_cadence_spm", "walk_mean_fi",
            "walk_fog_count",
        ] {
            XCTAssertNotNil(body[key], "required field \(key) missing from exam payload")
        }
        XCTAssertEqual(body["exam_uuid"] as? String, "exam-contract-1")
        XCTAssertEqual(body["voice_mean_dbfs"] as? Double, -26.5)
        XCTAssertEqual(body["handwriting_opencv_decay_pct"] as? Double, -22.0)
        XCTAssertEqual(body["walk_fog_count"] as? Int, 0)
    }

    /// The backend's response is kept, but what the wearer sees is the raw
    /// measurements, never the backend's score or state.
    func testTheSummaryShowsMeasurementsNotTheBackendScore() async {
        let mgr = HomeMotorExamManager(
            submitter: StubExamSubmitter(result: scoredResult), audio: .shared, sync: sync
        )
        var m = measurements()
        m.handwritingMeasured = true
        m.walkMeasured = true
        mgr.measurements = m

        let result = await mgr.completeExam(examUUID: "exam-score-1")
        XCTAssertEqual(result?.compositeMotorScore, 76.4)
        XCTAssertFalse(mgr.lastResultSummary?.contains("76") == true)
        XCTAssertFalse(mgr.lastResultSummary?.contains("WEARING") == true)
        XCTAssertTrue(mgr.lastResultSummary?.contains("22% smaller") == true, mgr.lastResultSummary ?? "")
        XCTAssertEqual(mgr.lastRecord?.handwritingDecayPct, -22.0)
    }

    /// A step that was not measured stays empty in the record.
    func testUnmeasuredStepsAreNotRecordedAsResults() async {
        let mgr = HomeMotorExamManager(
            submitter: StubExamSubmitter(result: scoredResult), audio: .shared, sync: sync
        )
        mgr.measurements = measurements()
        _ = await mgr.completeExam(examUUID: "exam-unmeasured-1")
        XCTAssertNil(mgr.lastRecord?.voiceMeanDbfs)
        XCTAssertNil(mgr.lastRecord?.handwritingDecayPct)
        XCTAssertNil(mgr.lastRecord?.walkStepsPerMinute)
    }

    /// Offline, the exam is queued for retry and the wearer is told the score
    /// is pending rather than being read a number the device made up.
    func testOfflineExamIsQueuedAndNoScoreIsInvented() async {
        let mgr = HomeMotorExamManager(
            submitter: StubExamSubmitter(result: nil), audio: .shared, sync: sync
        )
        mgr.measurements = measurements()

        let result = await mgr.completeExam(examUUID: "exam-offline-1")
        XCTAssertNil(result, "no score may be reported when the backend did not score it")
        XCTAssertNil(mgr.lastResult)
        XCTAssertEqual(mgr.currentStep, .completed)
        XCTAssertEqual(sync.pendingCount(), 1, "the exam must be queued for retry")

        let queued = sync.dueEvents().first
        XCTAssertEqual(queued?.endpoint, "/api/v1/exam/complete")
        XCTAssertTrue(mgr.lastResultSummary?.lowercased().contains("retry when connected") == true)
    }

    /// An exam with no SAM refinement omits the field rather than sending a
    /// JSON null. The backend accepts either form, so this pins the cleaner
    /// contract rather than guarding against a failure.
    func testOptionalSamRefinementIsOmittedWhenAbsent() async {
        let stub = StubExamSubmitter(result: scoredResult)
        let mgr = HomeMotorExamManager(submitter: stub, audio: .shared, sync: sync)
        var m = measurements()
        m.handwritingSamDecayPct = nil
        mgr.measurements = m

        _ = await mgr.completeExam(examUUID: "exam-nosam-1")
        let body = stub.submittedJSON[0]
        XCTAssertNil(
            body["handwriting_sam_decay_pct"],
            "absent SAM refinement should be omitted, not sent as null"
        )
    }

    /// The backend rejects an exam_uuid under 4 characters with a 422, so the
    /// generated identifiers must clear that floor.
    func testGeneratedExamIdentifiersMeetTheBackendMinimumLength() async {
        let stub = StubExamSubmitter(result: scoredResult)
        let mgr = HomeMotorExamManager(submitter: stub, audio: .shared, sync: sync)
        mgr.stepPauseSec = 0

        _ = await mgr.runDemoExam(measurements: measurements())
        let uuid = stub.submittedJSON[0]["exam_uuid"] as? String ?? ""
        XCTAssertGreaterThanOrEqual(uuid.count, 4, "exam_uuid '\(uuid)' is too short for the API")
    }

    /// The demo runner drives all three prompts and submits once.
    func testDemoRunnerCompletesAndSubmitsExactlyOnce() async {
        let stub = StubExamSubmitter(result: scoredResult)
        let mgr = HomeMotorExamManager(submitter: stub, audio: .shared, sync: sync)
        mgr.stepPauseSec = 0   // no waiting in tests

        let summary = await mgr.runDemoExam(measurements: measurements(), examUUID: "exam-demo-1")
        XCTAssertEqual(stub.submittedBodies.count, 1)
        XCTAssertEqual(mgr.currentStep, .completed)
        XCTAssertFalse(summary.contains("76.4"), "no score in the summary: \(summary)")
        XCTAssertTrue(summary.contains("steps a minute"), summary)
    }

    /// Task 1 vowel phonation recording via VoiceMonitor populates voice measurements
    /// upon advancing to Task 2 handwriting.
    func testVoiceMonitorPhonationRecordingPopulatesTask1Measurements() {
        let voiceMonitor = VoiceMonitor()
        let mgr = HomeMotorExamManager(submitter: StubExamSubmitter(result: scoredResult), audio: .shared, sync: sync, voiceMonitor: voiceMonitor)

        mgr.startExam()
        XCTAssertEqual(mgr.currentStep, .task1PromptedVoice)

        // Feed steady sustained vowel samples
        voiceMonitor.updateSampleLevel(dbfs: -22.0)
        voiceMonitor.updateSampleLevel(dbfs: -23.0)
        voiceMonitor.updateSampleLevel(dbfs: -21.0)
        voiceMonitor.updateSampleLevel(dbfs: -22.0)

        mgr.advanceToHandwriting()
        XCTAssertEqual(mgr.currentStep, .task2PromptedHandwriting)
        XCTAssertEqual(mgr.measurements.voiceMeanDbfs, -22.0, accuracy: 0.01)
        XCTAssertEqual(mgr.measurements.voiceStabilityDb, sqrt(0.5), accuracy: 0.01)
    }
}
