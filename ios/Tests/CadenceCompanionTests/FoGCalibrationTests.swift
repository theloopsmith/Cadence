import XCTest
@testable import CadenceCompanion

final class FoGCalibrationTests: XCTestCase {
    /// The bundled reference set has every label the calibrator needs.
    func testTheReferenceCaptureSetCoversEveryLabel() {
        let captures = LabeledCaptureLibrary.referenceCaptures()
        let labels = Set(captures.map(\.label))
        for required in GaitLabel.allCases {
            XCTAssertTrue(labels.contains(required), "missing \(required.rawValue) capture")
        }
        XCTAssertTrue(captures.allSatisfy { $0.source == .syntheticReference })
        XCTAssertTrue(captures.allSatisfy { $0.samples.count > 100 })
    }

    /// Thresholds come out of the labeled data, and walking sits clearly
    /// below the trigger while freezing sits clearly above it.
    func testCalibrationSeparatesWalkingFromFreezing() throws {
        let result = try FoGCalibrator().calibrate(LabeledCaptureLibrary.referenceCaptures())
        let t = result.thresholds

        XCTAssertGreaterThan(t.freezeIndexTrigger, result.report.walkingFreezeIndexP95)
        XCTAssertLessThan(t.freezeIndexTrigger, result.report.freezeFreezeIndexP05)
        XCTAssertLessThan(t.recoveryFreezeIndex, t.freezeIndexTrigger, "recovery needs hysteresis below the trigger")
        XCTAssertGreaterThan(t.locomotorArmingPower, 0)
        XCTAssertLessThan(t.locomotorArmingPower, result.report.walkingLocomotorP10, "every walking hop must arm")
        XCTAssertGreaterThan(t.dynamicEnergyFloor, result.report.stillEnergyP95, "sitting still must stay under the floor")
        XCTAssertEqual(result.report.source, .syntheticReference)
    }

    /// Turns and standing up are the classic false-positive traps. Their
    /// freeze index must stay under the trigger, and the report says so.
    func testTurnsAndSitToStandDoNotCrossTheTrigger() throws {
        let result = try FoGCalibrator().calibrate(LabeledCaptureLibrary.referenceCaptures())
        XCTAssertTrue(result.report.trapMargins.keys.contains(.turnUpright))
        XCTAssertTrue(result.report.trapMargins.keys.contains(.sitToStand))
        for (label, margin) in result.report.trapMargins {
            XCTAssertGreaterThan(margin, 0, "\(label.rawValue) peaks above the trigger")
        }
    }

    /// Without both walking and freezing captures there is nothing to separate.
    func testMissingLabelsIsAnError() {
        let onlyWalking = LabeledCaptureLibrary.referenceCaptures().filter { $0.label == .walking }
        XCTAssertThrowsError(try FoGCalibrator().calibrate(onlyWalking)) { error in
            guard case FoGCalibrationError.missingLabel(let label) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(label, .freeze)
        }
    }

    /// Mislabeled data (a walking capture labelled freeze) cannot be separated,
    /// and the calibrator refuses rather than emitting a threshold in the noise.
    func testOverlappingDistributionsAreRejected() {
        var captures = LabeledCaptureLibrary.referenceCaptures()
        if let walking = captures.first(where: { $0.label == .walking }) {
            captures.removeAll { $0.label == .freeze }
            var relabeled = walking
            relabeled.label = .freeze
            relabeled.id = "mislabeled"
            captures.append(relabeled)
        }
        XCTAssertThrowsError(try FoGCalibrator().calibrate(captures)) { error in
            guard case FoGCalibrationError.insufficientSeparation = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    /// The detector's defaults are the calibrated values, not literals.
    func testDetectorDefaultsMatchTheCalibration() throws {
        let calibrated = try FoGCalibrator().calibrate(LabeledCaptureLibrary.referenceCaptures()).thresholds
        let detector = FoGDetector()
        XCTAssertEqual(detector.thresholds.freezeIndexTrigger, calibrated.freezeIndexTrigger, accuracy: 1e-9)
        XCTAssertEqual(detector.thresholds.locomotorArmingPower, calibrated.locomotorArmingPower, accuracy: 1e-9)
        XCTAssertEqual(detector.thresholds.dynamicEnergyFloor, calibrated.dynamicEnergyFloor, accuracy: 1e-9)
    }

    /// Calibrated thresholds drive the live path end to end: the reference
    /// freeze capture cues, the walking and trap captures do not.
    func testCalibratedDetectorCuesOnFreezeAndNotOnTraps() {
        for capture in LabeledCaptureLibrary.referenceCaptures() {
            let engine = LiveEdgeEngine(fogDetector: FoGDetector(), fallDetector: FallDetector())
            var cued = false
            // Precede every capture with walking so the detector is armed the
            // way it would be mid-stride.
            if capture.label == .freeze {
                for s in LabeledCaptureLibrary.referenceCaptures().first(where: { $0.label == .walking })!.samples {
                    _ = engine.ingest(s)
                }
            }
            let offset = engine.fogDetector.hopDurationSec * 100
            for s in capture.samples {
                let shifted = IMUSample(
                    timestamp: s.timestamp + offset, ax: s.ax, ay: s.ay, az: s.az,
                    gx: s.gx, gy: s.gy, gz: s.gz, pitchDeg: s.pitchDeg, rollDeg: s.rollDeg
                )
                if engine.ingest(shifted).fogActive == true { cued = true }
            }
            AudioCueEngine.shared.stopRASMetronome()
            if capture.label == .freeze {
                XCTAssertTrue(cued, "the freeze capture must cue")
            } else {
                XCTAssertFalse(cued, "\(capture.label.rawValue) must not cue")
            }
        }
    }

    /// Prints the calibrated numbers so a reviewer can see what the detector runs on.
    func testPrintCalibratedThresholds() throws {
        let r = try FoGCalibrator().calibrate(LabeledCaptureLibrary.referenceCaptures())
        print(String(
            format: "[calibration] trigger=%.3f recovery=%.3f locoArming=%.4f energyFloor=%.5f | walkFI p95=%.3f freezeFI p05=%.3f walkLoco p10=%.4f stillE p95=%.6f",
            r.thresholds.freezeIndexTrigger, r.thresholds.recoveryFreezeIndex,
            r.thresholds.locomotorArmingPower, r.thresholds.dynamicEnergyFloor,
            r.report.walkingFreezeIndexP95, r.report.freezeFreezeIndexP05,
            r.report.walkingLocomotorP10, r.report.stillEnergyP95
        ))
        for (label, margin) in r.report.trapMargins.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print(String(format: "[calibration] trap %@ margin=%.3f", label.rawValue, margin))
        }
    }

    func testCapturesRoundTripThroughJSON() throws {
        let original = LabeledCaptureLibrary.referenceCaptures()[0]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LabeledCapture.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.label, original.label)
        XCTAssertEqual(decoded.samples.count, original.samples.count)
        XCTAssertEqual(decoded.samples[10].ay, original.samples[10].ay, accuracy: 1e-12)
    }

    func testTheStoreSavesAndLoadsRecordedCaptures() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("captures-\(UUID().uuidString)")
        let store = LabeledCaptureStore(directory: dir)
        let capture = LabeledCaptureLibrary.referenceCaptures()[0]
        try store.save(capture)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, capture.id)
        try store.remove(id: capture.id)
        XCTAssertEqual(try store.loadAll().count, 0)
    }

    /// Recorded phone captures replace the synthetic set only when they cover
    /// walking and freezing; a partial recording set is not enough.
    func testCalibrationSourcePrefersCompleteRecordedData() throws {
        let synthetic = LabeledCaptureLibrary.referenceCaptures()
        var recorded = synthetic.filter { $0.label == .walking || $0.label == .freeze || $0.label == .still }
        for i in recorded.indices { recorded[i].source = .phoneRecording }

        let partial = FoGCalibrationSource.choose(recorded: Array(recorded.prefix(1)), reference: synthetic)
        XCTAssertEqual(partial.source, .syntheticReference)

        let complete = FoGCalibrationSource.choose(recorded: recorded, reference: synthetic)
        XCTAssertEqual(complete.source, .phoneRecording)
        XCTAssertEqual(complete.captures.count, recorded.count)
    }
}
