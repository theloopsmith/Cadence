import XCTest
import PDFKit
@testable import CadenceCompanion

private final class HeldExamSubmitter: ExamSubmitting {
    var pending: CheckedContinuation<HomeMotorExamResult?, Never>?
    func submit(examJSON: Data, bearerToken: String) async -> HomeMotorExamResult? {
        await withCheckedContinuation { pending = $0 }
    }
}

@MainActor
final class ExamValidityTests: XCTestCase {
    private func queue() -> EventSyncManager {
        EventSyncManager(databasePath: NSTemporaryDirectory()+"valid-exam-\(UUID()).sqlite", startPeriodicDrain: false)
    }

    func testSecondPartialExamCannotReuseAnyPreviousMeasurement() async {
        let submitter = StubExamSubmitter(result: nil)
        let manager = HomeMotorExamManager(submitter: submitter, sync: queue())
        manager.startExam()
        var first = HomeMotorExamMeasurements()
        first.voiceMeanDbfs = -17; first.voiceMeasured = true
        first.handwritingOpencvDecayPct = -30; first.handwritingMeasured = true
        first.walkCadenceSpm = 110; first.walkMeasured = true
        manager.measurements = first
        _ = await manager.completeExam(examUUID: "first-full")
        manager.startExam()
        manager.skipVoice()
        manager.measurements.handwritingStatus = .skipped
        _ = await manager.completeExam(examUUID: "second-partial")
        let body = submitter.submittedJSON[1]
        for key in ["voice_mean_dbfs","voice_stability_db","handwriting_opencv_decay_pct","handwriting_sam_decay_pct","walk_cadence_spm","walk_mean_fi","walk_fog_count"] {
            XCTAssertNil(body[key], "unmeasured \(key) must not be transmitted")
        }
        XCTAssertEqual(body["voice_status"] as? String, "skipped")
        XCTAssertEqual(body["handwriting_status"] as? String, "skipped")
        XCTAssertNil(manager.lastRecord?.voiceMeanDbfs)
        XCTAssertNil(manager.lastRecord?.walkStepsPerMinute)
        XCTAssertEqual(TaskMetricsSummary.diaryDetail(manager.lastRecord!), "No tasks measured this time")
    }

    func testOfflineBodyAndLocalRecordAgreeOnPartialZeroValuedMeasurements() async {
        let sync = queue()
        let manager = HomeMotorExamManager(submitter: StubExamSubmitter(result: nil), sync: sync)
        manager.measurements.voiceMeanDbfs = 0
        manager.measurements.voiceStabilityDb = 0
        manager.measurements.voiceMeasured = true
        manager.measurements.walkStatus = .skipped
        _ = await manager.completeExam(examUUID: "zero-voice")
        let body = try! JSONSerialization.jsonObject(with: Data(sync.dueEvents()[0].payloadJSON.utf8)) as! [String: Any]
        XCTAssertEqual(body["voice_mean_dbfs"] as? Double, 0)
        XCTAssertEqual(body["voice_status"] as? String, "measured")
        XCTAssertNil(body["walk_cadence_spm"])
        XCTAssertEqual(manager.lastRecord?.voiceMeanDbfs, 0)
        XCTAssertNil(manager.lastRecord?.walkStepsPerMinute)
        XCTAssertTrue(TaskMetricsSummary.lines(current: manager.lastRecord!, previous: nil)[2].value.contains("Not measured"))
    }

    func testStableVoiceWithZeroVarianceIsMeasuredAndSkippedVoiceIsNot() {
        let monitor = VoiceMonitor()
        let manager = HomeMotorExamManager(submitter: StubExamSubmitter(result: nil), sync: queue(), voiceMonitor: monitor)
        manager.startExam()
        monitor.updateSampleLevel(dbfs: -25); monitor.updateSampleLevel(dbfs: -25)
        manager.advanceToHandwriting()
        XCTAssertTrue(manager.measurements.voiceMeasured)
        XCTAssertEqual(manager.measurements.voiceStabilityDb, 0)
        manager.startExam()
        manager.skipVoice()
        XCTAssertEqual(manager.measurements.voiceStatus, .skipped)
        XCTAssertFalse(manager.measurements.voiceMeasured)
    }

    func testInvalidNumbersAreUnavailableInsteadOfBreakingJsonOrLeakingToTrends() async {
        let submitter = StubExamSubmitter(result: nil)
        let manager = HomeMotorExamManager(submitter: submitter, sync: queue())
        manager.measurements.voiceMeasured = true
        manager.measurements.voiceMeanDbfs = .nan
        manager.measurements.walkMeasured = true
        manager.measurements.walkMeanFI = .infinity
        _ = await manager.completeExam(examUUID: "bad-numbers")
        XCTAssertEqual(submitter.submittedJSON.count, 1)
        XCTAssertEqual(submitter.submittedJSON[0]["voice_status"] as? String, "unavailable")
        XCTAssertNil(submitter.submittedJSON[0]["voice_mean_dbfs"])
        XCTAssertNil(manager.lastRecord?.voiceMeanDbfs)
        XCTAssertNil(manager.lastRecord?.walkStepsPerMinute)
    }

    func testUnseededDemoDoesNotInventMeasurements() async {
        let submitter = StubExamSubmitter(result: nil)
        let manager = HomeMotorExamManager(submitter: submitter, sync: queue())
        manager.stepPauseSec = 0
        _ = await manager.runDemoExam()
        XCTAssertNil(submitter.submittedJSON[0]["voice_mean_dbfs"])
        XCTAssertNil(submitter.submittedJSON[0]["handwriting_opencv_decay_pct"])
        XCTAssertNil(submitter.submittedJSON[0]["walk_cadence_spm"])
    }

    func testOldNetworkCompletionCannotOverwriteANewExam() async {
        let submitter = HeldExamSubmitter()
        let manager = HomeMotorExamManager(submitter: submitter, sync: queue())
        manager.startExam()
        let task = Task { await manager.completeExam(examUUID: "old-in-flight") }
        while submitter.pending == nil { await Task.yield() }
        manager.cancelExam()
        manager.startExam()
        let newSession = manager.examSessionID
        submitter.pending?.resume(returning: nil)
        _ = await task.value
        XCTAssertEqual(manager.examSessionID, newSession)
        XCTAssertEqual(manager.currentStep, .task1PromptedVoice)
        XCTAssertNil(manager.lastRecord)
        XCTAssertNil(manager.lastResultSummary)
    }

    func testPartialRecordStaysMissingInTheShareablePdf() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("partial-pdf-\(UUID())")
        let history = TaskMetricsHistory(directory: root.appendingPathComponent("metrics"))
        var measurements = HomeMotorExamMeasurements()
        measurements.voiceMeanDbfs = -24; measurements.voiceMeasured = true
        try history.append(measurements.record(at: Date()))
        let report = SummaryReportBuilder(diary: DiaryStore(directory: root.appendingPathComponent("diary")), metrics: history)
            .build(range: .lastDay, endingAt: Date(), name: "")
        XCTAssertTrue(report.plainText.contains("Not measured this time"))
        let pdf = try XCTUnwrap(PDFDocument(data: SummaryPDFRenderer().render(report)))
        let text = try XCTUnwrap(pdf.string)
        XCTAssertTrue(text.contains("Not measured this time"))
        XCTAssertFalse(text.contains("0 steps a minute"))
    }
}

final class WalkValidityTests: XCTestCase {
    func testGapInWalkCannotMasqueradeAsAnObservedZeroOrLowCadence() {
        let recorder = WalkTestRecorder()
        for i in 0..<200 {
            recorder.ingest(IMUSample(timestamp: Double(i)/50 + (i >= 100 ? 3 : 0), ax:0,ay:1,az:0,gx:0,gy:0,gz:0))
        }
        XCTAssertFalse(recorder.hasUsableRecording)
    }

    func testContinuousZeroStepRecordingCanBeDistinguishedFromNoRecording() {
        let recorder = WalkTestRecorder()
        XCTAssertFalse(recorder.hasUsableRecording)
        for i in 0..<200 { recorder.ingest(IMUSample(timestamp:Double(i)/50,ax:0,ay:1,az:0,gx:0,gy:0,gz:0)) }
        XCTAssertTrue(recorder.hasUsableRecording)
        XCTAssertEqual(recorder.finish().cadenceSpm, 0)
    }
}
