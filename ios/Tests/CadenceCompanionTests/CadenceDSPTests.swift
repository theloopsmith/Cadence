import XCTest
@testable import CadenceCompanion

final class CadenceDSPTests: XCTestCase {
    func testFoGSpectralIntegrationAndArmingStateMachine() {
        let detector = FoGDetector()
        let fs = 50.0
        var window: [IMUSample] = []
        for i in 0..<128 {
            let t = Double(i) / fs
            // Pure 5.5 Hz freeze oscillation in vertical axis
            let freezeSig = 0.80 * sin(2.0 * .pi * 5.5 * t)
            window.append(
                IMUSample(
                    timestamp: t,
                    ax: 0.0,
                    ay: 1.0 + freezeSig,
                    az: 0.0,
                    gx: 0.0,
                    gy: 0.0,
                    gz: 0.0,
                    pitchDeg: 5.0,
                    rollDeg: 2.0
                )
            )
        }

        let metrics = detector.computeSpectralMetrics(window: window, sampledHz: fs)
        XCTAssertGreaterThan(metrics.freezeBandPower, metrics.locomotorBandPower * 3.0)
        XCTAssertGreaterThan(metrics.freezeIndex, 2.0)

        // Verify 3 consecutive 0.50s hops (1.50s) armed via upright turn trigger FoG episode
        XCTAssertFalse(
            detector.evaluateHop(
                locomotorBandPower: 0.03,
                freezeBandPower: 0.15,
                integratedYaw15sDeg: 52.0,
                pitchDeg: 5.0,
                rollDeg: 2.0,
                sitToStandDetected: false,
                isUserSpeaking: false,
                sampledHz: fs
            )
        )
        XCTAssertFalse(
            detector.evaluateHop(
                locomotorBandPower: 0.03,
                freezeBandPower: 0.15,
                integratedYaw15sDeg: 52.0,
                pitchDeg: 5.0,
                rollDeg: 2.0,
                sitToStandDetected: false,
                isUserSpeaking: false,
                sampledHz: fs
            )
        )
        let thirdHopTriggered = detector.evaluateHop(
            locomotorBandPower: 0.03,
            freezeBandPower: 0.15,
            integratedYaw15sDeg: 52.0,
            pitchDeg: 5.0,
            rollDeg: 2.0,
            sitToStandDetected: false,
            isUserSpeaking: false,
            sampledHz: fs
        )
        XCTAssertTrue(thirdHopTriggered)
        XCTAssertEqual(detector.armingMode, .turningUpright)
        AudioCueEngine.shared.stopRASMetronome()
    }

    func testFallDetector3StageAndGroanVsAffirmativePhrase() {
        let detector = FallDetector()

        // Stage 1: Free-fall (<0.45g) at t=1.00s
        let s1 = detector.processIMUSample(
            IMUSample(timestamp: 1.00, ax: 0.1, ay: 0.1, az: 0.1, gx: 0, gy: 0, gz: 0, pitchDeg: 3.0, rollDeg: 1.0)
        )
        XCTAssertNil(s1)

        // Stage 2: Impact (>2.8g, jerk >35g/s) at t=1.10s
        let s2 = detector.processIMUSample(
            IMUSample(timestamp: 1.10, ax: 0.2, ay: 3.9, az: 0.3, gx: 2, gy: 2, gz: 1, pitchDeg: 20.0, rollDeg: 5.0)
        )
        XCTAssertNil(s2)

        // Stage 3: Post-impact horizontal stillness (tilt >55 deg, dynEnergy <0.015) at t=1.80s
        let eventUUID = detector.processIMUSample(
            IMUSample(timestamp: 1.80, ax: 0.98, ay: 0.15, az: 0.05, gx: 0, gy: 0, gz: 0, pitchDeg: 75.0, rollDeg: 4.0),
            latitude: 37.7749,
            longitude: -122.4194,
            horizontalAccuracyM: 5.0
        )
        XCTAssertNotNil(eventUUID)

        // Vocal groan (>-28 dBFS without affirmative phrase) MUST escalate even if unworn
        let groanOutcome = detector.evaluateCheckInOutcome(
            transcript: "ugh...",
            maxVocalLevelDbfs: -21.0,
            hardwareWearStateWorn: false,
            preImpactWearRmsG: 0.005,
            preImpactRespPower: 0.0,
            preImpactPitchDeg: 0.0
        )
        XCTAssertEqual(groanOutcome, "confirmed_waiting_dispatch")

        // Explicit multi-word affirmative phrase cancels false alarm
        let cancelOutcome = detector.evaluateCheckInOutcome(
            transcript: "I'm okay, just dropped my glasses",
            maxVocalLevelDbfs: -18.0,
            hardwareWearStateWorn: true,
            preImpactWearRmsG: 0.08,
            preImpactRespPower: 2.0e-5,
            preImpactPitchDeg: 5.0
        )
        XCTAssertEqual(cancelOutcome, "canceled_false_alarm")
        AudioCueEngine.shared.deactivateBystanderSiren()
    }

    func testVoiceMonitorVowelPhonationStability() {
        let sigma = VoiceMonitor.shared.computeVowelPhonationStabilityDb(
            vowelWindowDbfsSamples: [-20.0, -21.0, -19.0, -20.0]
        )
        XCTAssertEqual(sigma, sqrt(0.5), accuracy: 1e-6)
    }
}
