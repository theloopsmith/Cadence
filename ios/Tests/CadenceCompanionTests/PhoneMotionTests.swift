import XCTest
@testable import CadenceCompanion

final class PhoneMotionTests: XCTestCase {
    override func tearDown() {
        AudioCueEngine.shared.stopRASMetronome()
        AudioCueEngine.shared.deactivateBystanderSiren()
        super.tearDown()
    }

    private func magnitude(_ s: IMUSample) -> Double {
        sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az)
    }

    /// A phone at rest reports about 1 g along gravity, which is what the fall
    /// detector treats as "not falling".
    func testRestingPhoneKeepsGravityInTheSample() {
        let sample = PhoneMotionReading(
            timestamp: 1.0,
            userAccelerationG: (0, 0, 0),
            gravityG: (0, 0, -1),
            rotationRateRadPerSec: (0, 0, 0),
            pitchRad: 0.1,
            rollRad: -0.2
        ).makeIMUSample()

        XCTAssertEqual(magnitude(sample), 1.0, accuracy: 0.001)
        XCTAssertEqual(sample.pitchDeg, 0.1 * 180.0 / .pi, accuracy: 0.01)
        XCTAssertEqual(sample.rollDeg, -0.2 * 180.0 / .pi, accuracy: 0.01)
    }

    func testFreeFallDropsToNearZeroG() {
        let sample = PhoneMotionReading(
            timestamp: 2.0,
            userAccelerationG: (0, 0, 0),
            gravityG: (0, 0, 0),
            rotationRateRadPerSec: (0, 0, 0),
            pitchRad: 0,
            rollRad: 0
        ).makeIMUSample()
        XCTAssertEqual(magnitude(sample), 0.0, accuracy: 0.001)
    }

    /// Turning is rotation about gravity, not about whichever axis the phone
    /// happens to be lying on in a pocket.
    func testYawAboutGravityIntegratesOverOneAndAHalfSeconds() {
        var tracker = YawTurnTracker()
        let rate = 0.6 // rad/s about vertical
        let dt = 0.02
        for i in 0...75 {
            let t = Double(i) * dt
            tracker.add(timestamp: t, yawRateRadPerSec: rate)
        }
        let degrees = tracker.integratedDegrees()
        // 0.6 rad/s * 1.5 s = 0.9 rad = 51.6°
        XCTAssertEqual(degrees, 0.6 * 1.5 * 180.0 / .pi, accuracy: 0.5)
    }

    func testOscillatingYawDoesNotLookLikeATurn() {
        var tracker = YawTurnTracker()
        let dt = 0.02
        for i in 0...150 {
            let t = Double(i) * dt
            let rate = sin(2.0 * .pi * 1.8 * t)
            tracker.add(timestamp: t, yawRateRadPerSec: rate)
        }
        XCTAssertLessThan(abs(tracker.integratedDegrees()), 20.0)
    }

    func testSitToStandRequiresFiveSecondsOfStillnessThenASurge() {
        var monitor = SitToStandMonitor()
        for _ in 0..<9 {
            XCTAssertFalse(monitor.update(totalEnergy: 0.01, ay: 1.0, pitchDeg: 2.0))
        }
        XCTAssertFalse(
            monitor.update(totalEnergy: 0.2, ay: 1.5, pitchDeg: 20.0),
            "a surge before 5 s of stillness must not arm"
        )

        for _ in 0..<10 {
            XCTAssertFalse(monitor.update(totalEnergy: 0.01, ay: 0.99, pitchDeg: 2.0))
        }
        XCTAssertTrue(monitor.update(totalEnergy: 0.2, ay: 1.5, pitchDeg: 20.0))
        XCTAssertFalse(
            monitor.update(totalEnergy: 0.2, ay: 1.5, pitchDeg: 22.0),
            "the cue fires once per stillness period"
        )
    }

    func testLiveEngineConfirmsTheHardFallScenario() {
        let engine = LiveEdgeEngine()
        let samples = IMUScenarioReplayer.generateSamples(scenario: .hardFallWithImpact, sampleRateHz: 50)
        var confirmed: String?
        for sample in samples {
            let update = engine.ingest(sample, latitude: 37.77, longitude: -122.42, horizontalAccuracyM: 8)
            if let uuid = update.fallEventUUID {
                confirmed = uuid
                break
            }
        }
        XCTAssertNotNil(confirmed)
    }

    func testLiveEngineDetectsTheFreezeScenarioWithoutAForcedFreezeIndex() {
        let engine = LiveEdgeEngine()
        let samples = IMUScenarioReplayer.generateSamples(
            scenario: .freezeOfGaitWithRecovery,
            sampleRateHz: 50
        )
        var sawFreeze = false
        var peakFI = 0.0
        for sample in samples {
            let update = engine.ingest(sample)
            if update.fogActive == true { sawFreeze = true }
            if let fi = update.freezeIndex { peakFI = max(peakFI, fi) }
        }
        XCTAssertTrue(sawFreeze)
        XCTAssertGreaterThan(peakFI, 2.0)
    }

    func testLiveEngineArmsSitToStandFromTheSeatedScenario() {
        let engine = LiveEdgeEngine()
        let samples = IMUScenarioReplayer.generateSamples(scenario: .sitToStandInitiation, sampleRateHz: 50)
        var sawSitToStand = false
        for sample in samples {
            let update = engine.ingest(sample)
            if update.armingMode == FoGArmingMode.sitToStand.rawValue {
                sawSitToStand = true
            }
        }
        XCTAssertTrue(sawSitToStand, "standing up after 5 s seated must arm initiation")
    }

    func testLiveEngineDoesNotArmABedRollAsAnUprightTurn() {
        let engine = LiveEdgeEngine()
        let samples = IMUScenarioReplayer.generateSamples(scenario: .bedRollSuppression, sampleRateHz: 50)
        for sample in samples {
            let update = engine.ingest(sample)
            XCTAssertNotEqual(update.armingMode, FoGArmingMode.turningUpright.rawValue)
            XCTAssertNotEqual(update.fogActive, true)
        }
    }
}
