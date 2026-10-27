import XCTest
@testable import CadenceCompanion

final class IMUScenarioReplayTests: XCTestCase {
    override func tearDown() {
        AudioCueEngine.shared.stopRASMetronome()
        AudioCueEngine.shared.deactivateBystanderSiren()
        super.tearDown()
    }

    /// Tests the full FoG walk -> freeze -> metronome cue -> recovery cycle.
    func testFoGScenarioTriggersAndRecovers() {
        let detector = FoGDetector()
        let fs = 50.0
        let samples = IMUScenarioReplayer.generateSamples(
            scenario: .freezeOfGaitWithRecovery,
            sampleRateHz: fs
        )

        var sawEpisodeActive = false
        var sawEpisodeCleared = false

        // Feed samples in 0.50s hops (25 samples per hop @ 50 Hz, 128-sample sliding window)
        var window: [IMUSample] = []
        let windowSize = 128
        let hopSize = 25

        for i in stride(from: 0, to: samples.count - windowSize, by: hopSize) {
            window = Array(samples[i..<i + windowSize])
            let metrics = detector.computeSpectralMetrics(window: window, sampledHz: fs)

            let isEpisode = detector.evaluateHop(
                locomotorBandPower: metrics.locomotorBandPower,
                freezeBandPower: metrics.freezeBandPower,
                integratedYaw15sDeg: 0.0,
                pitchDeg: window.last?.pitchDeg ?? 0.0,
                rollDeg: window.last?.rollDeg ?? 0.0,
                sitToStandDetected: false,
                isUserSpeaking: false,
                sampledHz: fs
            )

            if isEpisode {
                sawEpisodeActive = true
                XCTAssertTrue(AudioCueEngine.shared.isMetronomeActive)
            } else if sawEpisodeActive {
                sawEpisodeCleared = true
            }
        }

        XCTAssertTrue(sawEpisodeActive, "5.5 Hz freeze oscillation must trigger FoG episode")
        XCTAssertTrue(sawEpisodeCleared, "Post-metronome locomotor recovery must clear FoG episode")
        XCTAssertFalse(AudioCueEngine.shared.isMetronomeActive, "Metronome must stop once cleared")
    }

    /// Tests that the hard fall scenario drives Stage 1, Stage 2, and Stage 3 to return an event UUID.
    func testHardFallScenarioConfirmsStage3AndOpensCheckIn() {
        let detector = FallDetector()
        let samples = IMUScenarioReplayer.generateSamples(
            scenario: .hardFallWithImpact,
            sampleRateHz: 50.0
        )

        var confirmedUUID: String?
        for sample in samples {
            if let uuid = detector.processIMUSample(
                sample,
                latitude: 37.7749,
                longitude: -122.4194,
                horizontalAccuracyM: 5.0
            ) {
                confirmedUUID = uuid
                break
            }
        }

        XCTAssertNotNil(confirmedUUID, "Hard fall scenario must trigger Stage 3 confirmation")
        if case .stage3CheckInActive(let eventUUID, _) = detector.stage {
            XCTAssertEqual(eventUUID, confirmedUUID)
        } else {
            XCTFail("Detector stage must be stage3CheckInActive")
        }
    }

    /// Tests that rolling over in bed (supine posture pitch > 65°) never arms FoG Mode C Upright Turn.
    func testBedRollNeverArmsUprightTurn() {
        let detector = FoGDetector()
        let fs = 50.0
        let samples = IMUScenarioReplayer.generateSamples(
            scenario: .bedRollSuppression,
            sampleRateHz: fs
        )

        let windowSize = 128
        let hopSize = 25

        for i in stride(from: 0, to: samples.count - windowSize, by: hopSize) {
            let window = Array(samples[i..<i + windowSize])
            let metrics = detector.computeSpectralMetrics(window: window, sampledHz: fs)

            let isEpisode = detector.evaluateHop(
                locomotorBandPower: metrics.locomotorBandPower,
                freezeBandPower: metrics.freezeBandPower,
                integratedYaw15sDeg: 55.0, // Significant yaw change during roll
                pitchDeg: window.last?.pitchDeg ?? 75.0, // Lying down
                rollDeg: window.last?.rollDeg ?? 25.0,
                sitToStandDetected: false,
                isUserSpeaking: false,
                sampledHz: fs
            )

            XCTAssertFalse(isEpisode)
            XCTAssertNotEqual(detector.armingMode, .turningUpright, "Bed roll must not arm upright turn mode")
        }
    }

    /// Tests that 5.0s seated stillness followed by a stand transition arms the Sit-to-Stand window.
    func testSitToStandArmsInitiationWindow() {
        let detector = FoGDetector()
        let fs = 50.0
        let samples = IMUScenarioReplayer.generateSamples(
            scenario: .sitToStandInitiation,
            sampleRateHz: fs
        )

        let windowSize = 128
        let hopSize = 25
        var sawArmedSitToStand = false

        for i in stride(from: 0, to: samples.count - windowSize, by: hopSize) {
            let window = Array(samples[i..<i + windowSize])
            let metrics = detector.computeSpectralMetrics(window: window, sampledHz: fs)
            let currentT = window.last?.timestamp ?? 0.0
            let transitionDetected = (currentT >= 5.5 && currentT <= 6.5)

            _ = detector.evaluateHop(
                locomotorBandPower: metrics.locomotorBandPower,
                freezeBandPower: metrics.freezeBandPower,
                integratedYaw15sDeg: 0.0,
                pitchDeg: window.last?.pitchDeg ?? 0.0,
                rollDeg: window.last?.rollDeg ?? 0.0,
                sitToStandDetected: transitionDetected,
                isUserSpeaking: false,
                sampledHz: fs
            )

            if detector.armingMode == .sitToStand {
                sawArmedSitToStand = true
            }
        }

        XCTAssertTrue(sawArmedSitToStand, "Sit-to-stand transition after stillness must arm initiation window")
    }
}
