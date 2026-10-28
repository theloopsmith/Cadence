import XCTest
@testable import CadenceCompanion

@MainActor
final class FoGCalibrationControllerTests: XCTestCase {
    private func tempStore() -> LabeledCaptureStore {
        LabeledCaptureStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("calib-\(UUID().uuidString)")
        )
    }

    func testWithNoRecordingsTheDetectorRunsOnTheReferenceSet() {
        let detector = FoGDetector(thresholds: FoGThresholds(
            freezeIndexTrigger: 99, recoveryFreezeIndex: 99, locomotorArmingPower: 99, dynamicEnergyFloor: 99
        ))
        let controller = FoGCalibrationController(store: tempStore(), detector: detector)
        controller.recalibrate()

        XCTAssertEqual(controller.source, .syntheticReference)
        XCTAssertEqual(detector.thresholds, FoGThresholds.calibratedReference)
        XCTAssertNotNil(controller.report)
        XCTAssertNil(controller.problem)
        XCTAssertEqual(controller.recordedCaptures.count, 0)
    }

    func testCompleteRecordingsReplaceTheReferenceSet() throws {
        let store = tempStore()
        for var capture in LabeledCaptureLibrary.referenceCaptures() where [.walking, .freeze, .still].contains(capture.label) {
            capture.source = .phoneRecording
            try store.save(capture)
        }
        let detector = FoGDetector()
        let controller = FoGCalibrationController(store: store, detector: detector)
        controller.recalibrate()

        XCTAssertEqual(controller.source, .phoneRecording)
        XCTAssertEqual(controller.recordedCaptures.count, 7)
        XCTAssertNil(controller.problem)
    }

    /// Recordings that cannot be separated are reported, and the detector
    /// keeps the reference thresholds instead of a meaningless one.
    func testBadRecordingsFallBackAndExplain() throws {
        let store = tempStore()
        let reference = LabeledCaptureLibrary.referenceCaptures()
        var walking = reference.first { $0.label == .walking }!
        walking.source = .phoneRecording
        var mislabeledFreeze = walking
        mislabeledFreeze.id = "bad-freeze"
        mislabeledFreeze.label = .freeze
        var still = reference.first { $0.label == .still }!
        still.source = .phoneRecording
        for c in [walking, mislabeledFreeze, still] { try store.save(c) }

        let detector = FoGDetector()
        let controller = FoGCalibrationController(store: store, detector: detector)
        controller.recalibrate()

        XCTAssertEqual(controller.source, .syntheticReference)
        XCTAssertEqual(detector.thresholds, FoGThresholds.calibratedReference)
        XCTAssertNotNil(controller.problem)
    }
}

@MainActor
final class LabeledCaptureRecorderTests: XCTestCase {
    func testRecordingCollectsSamplesAndSavesWithTheLabel() throws {
        let store = LabeledCaptureStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rec-\(UUID().uuidString)")
        )
        let feed = MotionFeed()
        feed.attach(fogDetector: FoGDetector(), fallDetector: FallDetector())
        let recorder = LabeledCaptureRecorder(motion: feed, store: store, source: .phoneRecording)

        recorder.start(label: .walking)
        XCTAssertTrue(recorder.isRecording)
        for i in 0..<200 {
            feed.ingest(IMUSample(timestamp: Double(i) / 100.0, ax: 0, ay: 1, az: 0, gx: 0, gy: 0, gz: 0))
        }
        XCTAssertEqual(recorder.sampleCount, 200)
        XCTAssertEqual(recorder.elapsedSec, 1.99, accuracy: 0.02)

        let saved = try XCTUnwrap(recorder.stopAndSave())
        XCTAssertEqual(saved.label, .walking)
        XCTAssertEqual(saved.source, .phoneRecording)
        XCTAssertEqual(saved.samples.count, 200)
        XCTAssertEqual(saved.sampleRateHz, 100.0, accuracy: 2.0)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(try store.loadAll().count, 1)

        // Samples after stop are not collected.
        feed.ingest(IMUSample(timestamp: 5, ax: 0, ay: 1, az: 0, gx: 0, gy: 0, gz: 0))
        XCTAssertEqual(recorder.sampleCount, 0)
    }

    func testStoppingAnEmptyRecordingSavesNothing() throws {
        let store = LabeledCaptureStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rec-\(UUID().uuidString)")
        )
        let feed = MotionFeed()
        feed.attach(fogDetector: FoGDetector(), fallDetector: FallDetector())
        let recorder = LabeledCaptureRecorder(motion: feed, store: store, source: .phoneRecording)
        recorder.start(label: .still)
        XCTAssertNil(recorder.stopAndSave())
        XCTAssertEqual(try store.loadAll().count, 0)
    }
}

@MainActor
final class WalkingModelTests: XCTestCase {
    private func makeModel() -> (WalkingModel, MotionFeed) {
        let feed = MotionFeed()
        let fall = FallAlertCoordinator(
            screen: NoopScreenController(), dialer: RecordingPhoneDialer(),
            sync: EventSyncManager(
                databasePath: NSTemporaryDirectory() + "walk-\(UUID().uuidString).sqlite",
                startPeriodicDrain: false
            ),
            locationProvider: MockLocationProvider(), speechListener: MockSpeechCheckInListener()
        )
        let model = WalkingModel(motion: feed, fallAlert: fall, location: MockLocationProvider())
        return (model, feed)
    }

    /// The headline is plain language, not detector state names.
    func testStatusTextIsPlainLanguage() {
        let (model, feed) = makeModel()
        XCTAssertEqual(model.headline, "Protection is off")
        XCTAssertFalse(model.headline.lowercased().contains("fog"))

        feed.attach(fogDetector: model.fogDetector, fallDetector: model.fallAlert.detector)
        let walking = LabeledCaptureLibrary.referenceCaptures().first { $0.label == .walking }!
        for s in walking.samples { feed.ingest(s) }
        // Walking is being tracked, but protection (the live sensor) is not on
        // in this test, so the sentence is about what the phone sees.
        XCTAssertFalse(model.isCueing)
        XCTAssertEqual(model.detailForTesting(armingMode: "walking", cueing: false), "Walking steadily")
        XCTAssertEqual(model.detailForTesting(armingMode: "disarmed", cueing: false), "Standing or sitting")
        XCTAssertEqual(model.detailForTesting(armingMode: "walking", cueing: true), "Playing a steady beat to help you step")
    }

    /// The demo pushes a real freeze through the real detector, is flagged as
    /// a demo the whole time, and the cue plays then stops on its own.
    func testTheLabeledDemoPlaysACueThroughTheRealDetector() async {
        let (model, _) = makeModel()
        model.demoSampleIntervalNs = 0

        model.startFreezeDemo()
        XCTAssertTrue(model.isDemoRunning)
        XCTAssertEqual(model.demoLabel, "Demo")

        for _ in 0..<400 {
            if !model.isDemoRunning { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.isDemoRunning)
        let cueSeconds = model.lastDemoCueSeconds ?? 0
        XCTAssertGreaterThan(cueSeconds, 2.0, "the demo must produce an audible cue")
        XCTAssertLessThan(cueSeconds, 10.0, "the cue must end once walking resumes")
        XCTAssertFalse(model.isCueing, "the cue must stop when walking resumes")
        XCTAssertNotNil(model.lastDemoSummary)
        AudioCueEngine.shared.stopRASMetronome()
    }

    func testStoppingTheDemoSilencesTheCue() async {
        let (model, _) = makeModel()
        model.demoSampleIntervalNs = 2_000_000
        model.startFreezeDemo()
        try? await Task.sleep(nanoseconds: 50_000_000)
        model.stopFreezeDemo()
        XCTAssertFalse(model.isDemoRunning)
        XCTAssertFalse(model.isCueing)
        XCTAssertFalse(AudioCueEngine.shared.isMetronomeActive)
    }

    /// On a Mac there are no motion sensors; protection explains rather than
    /// pretending to be on.
    func testProtectionWithoutSensorsExplains() {
        let (model, feed) = makeModel()
        model.setProtection(enabled: true)
        if !feed.sourceIsAvailable {
            XCTAssertFalse(model.isProtectionOn)
            XCTAssertTrue(model.headline.lowercased().contains("not available"))
        }
    }
}
