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

// MARK: - Transcript matching regressions (code review, Oct 26)

final class FallTranscriptMatchingTests: XCTestCase {
    private func outcome(_ transcript: String) -> String {
        let detector = FallDetector()
        return detector.evaluateCheckInOutcome(
            transcript: transcript,
            maxVocalLevelDbfs: -50.0,   // silent: isolates transcript logic
            hardwareWearStateWorn: true,
            preImpactWearRmsG: 0.08,
            preImpactRespPower: 2.0e-5,
            preImpactPitchDeg: 5.0
        )
    }

    /// "no" must match as a whole word. Matching it as a bare substring made
    /// "now", "know" and "nothing" escalate, so an alert could not be
    /// cancelled by the most natural phrasings a wearer actually uses.
    func testShortNegationKeywordDoesNotMatchInsideOtherWords() {
        XCTAssertEqual(outcome("I'm fine now"), "canceled_false_alarm")
        XCTAssertEqual(outcome("I know I'm okay"), "canceled_false_alarm")
        XCTAssertEqual(outcome("nothing is wrong, I'm fine"), "canceled_false_alarm")
        XCTAssertEqual(outcome("I'm okay, no need to call anyone"), "confirmed_waiting_dispatch")
        AudioCueEngine.shared.deactivateBystanderSiren()
    }

    /// Inflected distress words must still escalate: "my knee hurts" is exactly
    /// the kind of utterance that must never be read as a cancellation, and
    /// whole-word matching alone would have missed it.
    func testInflectedDistressWordsStillEscalate() {
        XCTAssertEqual(outcome("my knee hurts"), "confirmed_waiting_dispatch")
        XCTAssertEqual(outcome("my hip is hurting"), "confirmed_waiting_dispatch")
        XCTAssertEqual(outcome("I have fallen"), "confirmed_waiting_dispatch")
        XCTAssertEqual(outcome("it pains me to move"), "confirmed_waiting_dispatch")
        AudioCueEngine.shared.deactivateBystanderSiren()
    }

    /// Inflection matching must not become a loose prefix match: unrelated
    /// words that merely start with a keyword are not distress signals.
    func testInflectionMatchingDoesNotFireOnUnrelatedWords() {
        // "helping", "nos" etc. are inflections and may fire; these are words
        // that share a prefix but are not inflections of the keyword.
        XCTAssertEqual(outcome("I'm fine, the helmet took it"), "canceled_false_alarm")
        XCTAssertEqual(outcome("I'm okay, nothing painted on it"), "canceled_false_alarm")
        AudioCueEngine.shared.deactivateBystanderSiren()
    }

    /// A standalone "no" is still a negation and must escalate.
    func testStandaloneNegationStillEscalates() {
        XCTAssertEqual(outcome("no"), "confirmed_waiting_dispatch")
        XCTAssertEqual(outcome("No. I'm okay"), "confirmed_waiting_dispatch")
        XCTAssertEqual(outcome("I'm not okay"), "confirmed_waiting_dispatch")
        XCTAssertEqual(outcome("I'm okay but my knee hurts"), "confirmed_waiting_dispatch")
        AudioCueEngine.shared.deactivateBystanderSiren()
    }

    /// Apostrophes survive normalization, including the typographic apostrophe
    /// that SFSpeechRecognizer emits, so contracted phrases still match.
    func testContractedPhrasesMatchWithEitherApostrophe() {
        XCTAssertEqual(outcome("I'm okay"), "canceled_false_alarm")
        XCTAssertEqual(outcome("I\u{2019}m okay"), "canceled_false_alarm")
        XCTAssertEqual(outcome("don't call anyone"), "canceled_false_alarm")
        XCTAssertEqual(outcome("I can't get up"), "confirmed_waiting_dispatch")
        XCTAssertEqual(outcome("I can\u{2019}t get up"), "confirmed_waiting_dispatch")
        XCTAssertEqual(outcome("I cannot get up"), "confirmed_waiting_dispatch")
        AudioCueEngine.shared.deactivateBystanderSiren()
    }

    /// Bare "okay" must never cancel: that is the rule the whole phrase list exists for.
    func testBareOkayNeverCancels() {
        XCTAssertEqual(outcome("okay"), "confirmed_waiting_dispatch")
        XCTAssertEqual(outcome("okay okay okay"), "confirmed_waiting_dispatch")
        AudioCueEngine.shared.deactivateBystanderSiren()
    }

    /// A groan above -28 dBFS escalates even with no words and no wear signal.
    func testGroanOverridesSilenceAndWearState() {
        let detector = FallDetector()
        let res = detector.evaluateCheckInOutcome(
            transcript: nil,
            maxVocalLevelDbfs: -20.0,
            hardwareWearStateWorn: false,
            preImpactWearRmsG: 0.001,
            preImpactRespPower: 0.0,
            preImpactPitchDeg: 0.0
        )
        XCTAssertEqual(res, "confirmed_waiting_dispatch")
        AudioCueEngine.shared.deactivateBystanderSiren()
    }

    /// Suppression stays off by default, so a silent unworn drop still escalates
    /// until the Day-2 supine-vs-table calibration enables the gate.
    func testUnwornDropSuppressionIsOffByDefault() {
        let detector = FallDetector()
        XCTAssertFalse(detector.enableUnwornDropSuppression)
        let res = detector.evaluateCheckInOutcome(
            transcript: nil,
            maxVocalLevelDbfs: -60.0,
            hardwareWearStateWorn: false,
            preImpactWearRmsG: 0.001,
            preImpactRespPower: 0.0,
            preImpactPitchDeg: 0.0
        )
        XCTAssertEqual(res, "confirmed_waiting_dispatch")

        detector.enableUnwornDropSuppression = true
        let suppressed = detector.evaluateCheckInOutcome(
            transcript: nil,
            maxVocalLevelDbfs: -60.0,
            hardwareWearStateWorn: false,
            preImpactWearRmsG: 0.001,
            preImpactRespPower: 0.0,
            preImpactPitchDeg: 0.0
        )
        XCTAssertEqual(suppressed, "suppressed_unworn_drop")
        AudioCueEngine.shared.deactivateBystanderSiren()
    }
}
